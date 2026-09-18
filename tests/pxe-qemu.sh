#!/bin/bash
# PXE-boot the netboot payload (out/netboot.tar.gz) in QEMU and drive it over the serial console.
#
#   ./pxe-qemu.sh [netboot.tar.gz]
#
# There is no DHCP/TFTP server here on purpose: QEMU's user-mode network stack has both built in.
# `-netdev user,tftp=DIR,bootfile=pxelinux.0` makes QEMU answer DHCP/BOOTP, hand out pxelinux.0
# and serve it — plus the pxelinux config, the kernel and the initrd — over its own TFTP server.
# The guest reaches the host at 10.0.2.2, which is where the squashfs comes from over HTTP.
#
# This proves the tftpboot/ layout produced by `lb config -b netboot --bootloaders syslinux` is
# actually bootable. It does NOT prove anything about a real DHCP/TFTP server.
#
# Why the HTTP step: the kernel command line baked into the payload is
#     boot=live components console=tty0 console=ttyS0,115200
# with no transport for the root filesystem, and the tftpboot tree does not contain the squashfs
# at all (it lives at debian-live/live/filesystem.squashfs in the same tarball). live-boot(7)
# documents `fetch=URL` for exactly this ("webbooting"), so the payload needs one extra kernel
# parameter to be usable. That is a gap in the shipped artifact, not just in this test.
set -u

SCRATCH=/mnt/scratch
TARBALL="${1:-$SCRATCH/netboot.tar.gz}"
WORK="$SCRATCH/pxe"
HTTP_PORT=8000
PORT=4570
MPORT=4571
DEADLINE=${DEADLINE:-900}
LOG="$SCRATCH/pxe.log"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

say "unpacking $TARBALL"
ls -lh "$TARBALL" || exit 1
rm -rf "$WORK"; mkdir -p "$WORK"
tar xzf "$TARBALL" -C "$WORK" || exit 1
ls -la "$WORK"

TFTP="$WORK/tftpboot"
SQUASH_REL=""
for cand in debian-live/live/filesystem.squashfs live/filesystem.squashfs; do
  [[ -f "$WORK/$cand" ]] && { SQUASH_REL="$cand"; break; }
done
[[ -n "$SQUASH_REL" ]] || { echo "no filesystem.squashfs in the tarball"; find "$WORK" -name 'filesystem.squashfs'; exit 1; }
echo "squashfs: $SQUASH_REL ($(du -h "$WORK/$SQUASH_REL" | cut -f1))"
[[ -f "$TFTP/pxelinux.0" ]] || { echo "no tftpboot/pxelinux.0"; exit 1; }

# Add the root-filesystem transport. PXELINUX config: the default entry is in live.cfg, pulled in
# by menu.cfg. Patch the amd64 default entry in place and show what changed.
say "adding fetch= to the kernel command line"
cp "$TFTP/live.cfg" "$TFTP/live.cfg.orig"
python3 - "$TFTP/live.cfg" "http://10.0.2.2:$HTTP_PORT/$SQUASH_REL" <<'PY'
import re, sys
path, url = sys.argv[1], sys.argv[2]
src = open(path).read()
# Only the first (default) entry: the fail-safe entry is not what we boot.
out, done = [], False
for line in src.splitlines():
    if not done and line.strip().startswith("append "):
        line = line.rstrip() + " fetch=" + url
        done = True
    out.append(line)
open(path, "w").write("\n".join(out) + "\n")
PY
grep -A3 '^label live-amd64$' "$TFTP/live.cfg"

say "serving $WORK over HTTP on port $HTTP_PORT"
( cd "$WORK" && exec python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 ) >"$SCRATCH/pxe-http.log" 2>&1 &
HTTPPID=$!
sleep 2
kill -0 "$HTTPPID" 2>/dev/null || { echo "HTTP server failed:"; cat "$SCRATCH/pxe-http.log"; exit 1; }

rm -f "$LOG" "$SCRATCH/qemu-pxe.err"
say "booting (PXE from QEMU's built-in TFTP, serial tcp:$PORT)"
qemu-system-x86_64 -m 4096 -smp 2 -enable-kvm \
  -netdev "user,id=n1,tftp=$TFTP,bootfile=pxelinux.0" \
  -device virtio-net-pci,netdev=n1 \
  -boot n \
  -display none -monitor tcp:127.0.0.1:$MPORT,server,nowait \
  -serial tcp:127.0.0.1:$PORT,server,nowait \
  </dev/null >"$SCRATCH/qemu-pxe.err" 2>&1 &
QPID=$!

wait_port() {
  local p="$1" i
  for (( i = 0; i < 40; i++ )); do
    (exec 9<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && return 0
    kill -0 "$QPID" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}
cleanup() {
  kill "$QPID" "$HTTPPID" 2>/dev/null
  wait "$QPID" 2>/dev/null
}
trap cleanup EXIT

wait_port "$MPORT" || { echo "no monitor socket"; tail -5 "$SCRATCH/qemu-pxe.err"; exit 1; }
exec 4<>"/dev/tcp/127.0.0.1/$MPORT"
wait_port "$PORT"  || { echo "no serial socket";  tail -5 "$SCRATCH/qemu-pxe.err"; exit 1; }
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
cat <&3 > "$LOG" &
CATPID=$!

# PXELINUX's menu has `timeout 0`, which in syslinux means WAIT FOREVER — so it needs a keypress.
# The menu is a VGA vesamenu, so this goes to the monitor as a keyboard event.
( sleep 15; printf 'sendkey ret\n' ) >&4 2>/dev/null &

say "waiting (deadline ${DEADLINE}s)"
up=0
for (( t = 0; t < DEADLINE; t++ )); do
  if grep -qaE "Kernel panic|Attempted to kill init|No such file|Unable to find" "$LOG" 2>/dev/null; then
    echo "  [t=${t}s] failure marker in the console"; break
  fi
  if grep -qa "login:" "$LOG" 2>/dev/null; then
    up=1; echo "  [t=${t}s] live system reached a login prompt"; break
  fi
  sleep 1
done

sleep 5
printf 'quit\n' >&4
for _ in $(seq 1 20); do kill -0 "$QPID" 2>/dev/null || break; sleep 1; done
kill "$QPID" "$CATPID" "$HTTPPID" 2>/dev/null
wait "$QPID" 2>/dev/null
trap - EXIT

echo
echo "=== PXE markers ==="
grep -aoE "PXE|pxelinux|Trying to load|Loading|Please unlock|live-boot|fetch|Fetching|squashfs|Welcome to Debian|Debian GNU/Linux 13|login:|Kernel panic" \
  "$LOG" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sort | uniq -c | sort -rn | head -15
echo "=== HTTP requests served ==="
grep -aoE '"(GET|HEAD) [^"]+" [0-9]+' "$SCRATCH/pxe-http.log" 2>/dev/null | tail -8
echo "=== last lines ==="
tr -d '\000' < "$LOG" | sed 's/\x1b\[[0-9;]*m//g' | tail -20

if (( up )); then
  echo; echo "RESULT: PASS — the netboot payload PXE-booted to a live login prompt."
  exit 0
fi
echo; echo "RESULT: FAIL — the netboot payload did not reach a login prompt."
exit 1
