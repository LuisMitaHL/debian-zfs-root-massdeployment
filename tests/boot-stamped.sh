#!/bin/bash
# Boot a *stamped* disk image in QEMU/BIOS and drive the LUKS prompt over the serial console.
# No ISO: this is the stamped machine starting on its own, which is the one thing the whole
# project is for.
#
#   ./boot-stamped.sh [image] [passphrase] [extra-image...]
#
# One disk boots a mini image; pass a mirror pair (server0.img PASS server1.img) to boot
# the server profile, exercising the mdadm RAID1 /boot and multi-container unlock. Every
# LUKS prompt on the console is answered; single-disk boot (DESIGN.md §14) is just the
# pair with one image omitted.
#
# BIOS, not UEFI, on purpose: no OVMF, no NVRAM, no vars.fd, and — unlike UEFI in this VM —
# SeaBIOS has never dropped into a firmware shell mid-test.
#
# The stamped profile MUST set SERIAL_CONSOLE (e.g. "ttyS0,115200"). Without it the kernel
# never writes to ttyS0, the whole boot is invisible, and the LUKS prompt goes to a VGA
# framebuffer nobody is looking at. See remaining.md.
set -u

SCRATCH=/mnt/scratch
IMG="${1:-$SCRATCH/single.img}"
PASS="${2:-smoke-test-passphrase}"
shift $(( $# >= 2 ? 2 : $# ))
# Extra images ($3...) attach as further virtio disks. $1/$2 keep their historical
# meaning so existing single-disk callers are unaffected.
EXTRA_IMGS=("$@")
PORT=4555
MPORT=4556
DEADLINE=${DEADLINE:-360}   # seconds of guest time before we give up
# Never boot the only copy: ZFS writes to the pool during import, and a half-finished boot
# leaves the image in a state we may want to compare against.
BOOTIMG="$SCRATCH/boot-test.img"
LOG="$SCRATCH/boot.log"

rm -f "$LOG" "$SCRATCH/qemu-boot.err"
echo "=== source image(s) ==="
ls -lh "$IMG" ${EXTRA_IMGS[@]+"${EXTRA_IMGS[@]}"}

echo "=== copying (the originals stay untouched) ==="
rm -f "$BOOTIMG" "$SCRATCH"/boot-test-*.img
cp --sparse=always "$IMG" "$BOOTIMG" || exit 1
ls -lh "$BOOTIMG"
BOOT_EXTRA=()
i=1
for e in ${EXTRA_IMGS[@]+"${EXTRA_IMGS[@]}"}; do
  cp --sparse=always "$e" "$SCRATCH/boot-test-$i.img" || exit 1
  BOOT_EXTRA+=("$SCRATCH/boot-test-$i.img")
  i=$((i + 1))
done

echo "=== booting (BIOS, serial tcp:$PORT, monitor tcp:$MPORT) ==="
EXTRA_QEMU=""
i=1
for e in ${BOOT_EXTRA[@]+"${BOOT_EXTRA[@]}"}; do
  EXTRA_QEMU="$EXTRA_QEMU -drive file=$e,format=raw,if=none,id=d$i -device virtio-blk-pci,drive=d$i,serial=zfstarget$i"
  i=$((i + 1))
done
# shellcheck disable=SC2086
qemu-system-x86_64 -m 4096 -smp 2 -enable-kvm \
  -drive file="$BOOTIMG",format=raw,if=none,id=d0 \
  -device virtio-blk-pci,drive=d0,serial=zfstarget \
  $EXTRA_QEMU \
  -boot order=c \
  -display none -monitor tcp:127.0.0.1:$MPORT,server,nowait \
  -serial tcp:127.0.0.1:$PORT,server,nowait \
  </dev/null >"$SCRATCH/qemu-boot.err" 2>&1 &
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

if ! wait_port "$MPORT"; then echo "no monitor socket"; tail -5 "$SCRATCH/qemu-boot.err"; kill "$QPID" 2>/dev/null; exit 1; fi
exec 4<>"/dev/tcp/127.0.0.1/$MPORT"
if ! wait_port "$PORT"; then echo "no serial socket"; tail -5 "$SCRATCH/qemu-boot.err"; kill "$QPID" 2>/dev/null; exit 1; fi
exec 3<>"/dev/tcp/127.0.0.1/$PORT"

# Drain the serial console into a log we can grep.
cat <&3 > "$LOG" &
CATPID=$!

# Answer the LUKS prompt. Poll the captured log instead of sleeping a fixed amount: the prompt
# appears at a different moment on every machine, and typing the passphrase into GRUB's menu
# rather than the initramfs prompt is the classic way to get an inexplicable hang.
sent=0
unlocked=0
up=0
for (( t = 0; t < DEADLINE; t++ )); do
  n=$(grep -ac "unlock disk" "$LOG" 2>/dev/null || true); n=${n:-0}
  if (( n > sent )); then
    sent=$n
    printf '%s\n' "$PASS" >&3
    echo "  [t=${t}s] answered LUKS prompt #$sent"
  fi
  if (( ! unlocked )) && grep -qaE "set up successfully|Command successful" "$LOG" 2>/dev/null; then
    unlocked=1; echo "  [t=${t}s] container unlocked"
  fi
  if grep -qa "Kernel panic\|Attempted to kill init" "$LOG" 2>/dev/null; then
    echo "  [t=${t}s] PANIC"; up=-1; break
  fi
  # An initramfs shell means the disks were unlocked but root could not be mounted — a real
  # failure, and worth reporting in seconds rather than after the whole deadline.
  if grep -qa "(initramfs)" "$LOG" 2>/dev/null; then
    echo "  [t=${t}s] dropped to an (initramfs) shell — root could not be mounted"
    up=-1; break
  fi
  if grep -qa "login:" "$LOG" 2>/dev/null; then
    up=1; echo "  [t=${t}s] login prompt reached"; break
  fi
  sleep 1
done

# Optional: log in after the prompt and run commands, so a degraded boot can be
# inspected from inside (mdadm state, pool topology). Used for the single-disk
# server boot: LOGIN_USER=smokeuser LOGIN_PASS=smoke-test-passphrase.
# POST_CMDS defaults to a degraded-state dump.
if (( up == 1 )) && [[ -n "${LOGIN_USER:-}" ]]; then
  echo "  logging in as $LOGIN_USER"
  printf '%s\n' "$LOGIN_USER" >&3
  for (( t = 0; t < 30; t++ )); do
    grep -qa "Password:" "$LOG" 2>/dev/null && break
    sleep 1
  done
  printf '%s\n' "${LOGIN_PASS:-}" >&3
  sleep 6
  printf '%s\n' "${POST_CMDS:-mdadm --detail /dev/md0 | head -12; zpool status -x; zpool list; swapon --show; systemctl --failed --no-legend | head -5; echo POST_DONE}" >&3
  sleep 20
  echo "  post-boot commands sent"
fi

# Give the login prompt a moment to flush, then stop the guest from the monitor.
sleep 8
printf 'quit\n' >&4
for _ in $(seq 1 20); do kill -0 "$QPID" 2>/dev/null || break; sleep 1; done
kill "$QPID" 2>/dev/null
kill "$CATPID" 2>/dev/null
wait "$QPID" 2>/dev/null

echo
echo "=== result: up=$up unlocked=$unlocked prompts=$sent ==="
echo "=== boot markers ==="
grep -aoE "GRUB version [0-9.]+|Loading Linux|Please unlock disk [A-Za-z0-9]+|Command successful|Importing pool|zfs-mount|Welcome to Debian|Debian GNU/Linux 13|login:|Kernel panic|Attempted to kill init" \
  "$LOG" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sort | uniq -c | sort -rn | head -20
echo "=== last lines ==="
tr -d '\000' < "$LOG" | sed 's/\x1b\[[0-9;]*m//g' | tail -30

if (( up == 1 )); then
  echo
  echo "RESULT: PASS — the stamped image booted to a login prompt."
  exit 0
fi
echo
echo "RESULT: FAIL — the stamped image did not reach a login prompt."
exit 1
