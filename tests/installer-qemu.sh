#!/bin/bash
# Drive the live installer ISO in QEMU over the serial console and stamp ONE disk (mini-PC style).
#
#   cdrom   : the installer ISO
#   vdb     : the target disk (serial=zfstarget -> /dev/disk/by-id/virtio-zfstarget)
#   vdc     : the carrier medium (golden stream, boot payload, profile, key, stamp script)
#
# The stamp script is taken from the CARRIER, not from the copy baked into the ISO. That is
# deliberate: it means a change to scripts/zfs-stamp.sh can be tested in ~15 minutes instead of
# after a ~16-minute ISO rebuild, and it matches the project's "the ISO is static, the carrier
# carries the payload" model. The ISO's own /usr/local/sbin/zfs-stamp.sh is the same file at
# release time — build-live.sh installs it from this repository.
#
# The live environment has no automation hooks, so this logs in over the serial console and
# types the commands. Timings are generous on purpose.
set -u

SCRATCH=/mnt/scratch
ISO="$SCRATCH/debian-zfs-installer.iso"
GOLD="$SCRATCH/smoke/out"
CARRIER="$SCRATCH/carrier.img"
TARGET="$SCRATCH/single.img"
REPO="${REPO:-/root/debian-zfs-root}"
PORT=4560
MPORT=4561

echo "=== preparing the carrier ($(du -sh "$GOLD" 2>/dev/null | cut -f1) of golden data) ==="
rm -f "$CARRIER"
truncate -s 3G "$CARRIER"
mkfs.ext4 -q -F -L CARRIER "$CARRIER"
mkdir -p /mnt/carrier
mount -o loop "$CARRIER" /mnt/carrier
cp "$GOLD/rpool.stream.zst" /mnt/carrier/
cp "$GOLD/boot.tar.zst" /mnt/carrier/
# crypttab(5): the passphrase must not be followed by a newline.
printf 'smoke-test-passphrase' > /mnt/carrier/luks.key
rm -f /mnt/carrier/dropbear.pub /mnt/carrier/dropbear
ssh-keygen -q -t ed25519 -N '' -f /mnt/carrier/dropbear
install -m 0755 "$REPO/scripts/zfs-stamp.sh" /mnt/carrier/zfs-stamp.sh
cat > /mnt/carrier/mini.conf <<'EOF'
PROFILE_NAME="mini-single"
CLASS="mini"
HOSTNAME="mini01"
DISKS=(/dev/disk/by-id/virtio-zfstarget)
TOPOLOGY="single"
BOOT_MODE="bios"
SWAP="ephemeral"
SWAP_SIZE="2G"
ZSWAP="yes"
ZRAM="no"
CRYPT="yes"
LUKS_KEYFILE="/media/carrier/luks.key"
DROPBEAR_AUTHORIZED_KEYS="/media/carrier/dropbear.pub"
ADDRESS="dhcp"
# The only way to observe a BIOS boot in this VM. Also what a headless machine wants.
SERIAL_CONSOLE="ttyS0,115200"
EOF
sync
umount /mnt/carrier
echo "carrier ready: $(du -h "$CARRIER" | cut -f1)"
echo "stamp script on carrier: $(md5sum "$REPO/scripts/zfs-stamp.sh" | cut -c1-12)"

echo "=== preparing the single target disk ==="
rm -f "$TARGET"
truncate -s 16G "$TARGET"

rm -f "$SCRATCH/installer.log" "$SCRATCH/qemu.err"
echo "=== booting the installer ==="
qemu-system-x86_64 -m 4096 -smp 2 -enable-kvm \
  -cdrom "$ISO" \
  -drive file="$TARGET",format=raw,if=none,id=target0 \
  -device virtio-blk-pci,drive=target0,serial=zfstarget \
  -drive file="$CARRIER",format=raw,if=virtio \
  -boot order=d \
  -display none -monitor tcp:127.0.0.1:$MPORT,server,nowait \
  -serial tcp:127.0.0.1:$PORT,server,nowait \
  </dev/null >"$SCRATCH/qemu.err" 2>&1 &
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
wait_port "$MPORT" || { echo "no monitor socket"; tail -5 "$SCRATCH/qemu.err"; exit 1; }
exec 4<>"/dev/tcp/127.0.0.1/$MPORT"
wait_port "$PORT"  || { echo "no serial socket";  tail -5 "$SCRATCH/qemu.err"; exit 1; }
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
cat <&3 > "$SCRATCH/installer.log" &
CATPID=$!

# Keystrokes. The syslinux menu is accepted with a MONITOR sendkey (a keyboard event, i.e.
# Enter on the VGA console) — proven, and independent of whether syslinux is on the serial line.
(
  sleep 12; printf 'sendkey ret\n'
  sleep 2;  printf 'sendkey ret\n'
) >&4 2>/dev/null &

# Everything after that is typed on the SERIAL console, whose timings are the ones that worked
# before; they are generous because the live environment takes ~90s to reach a login prompt.
(
  sleep 95; printf 'user\n'                       # Debian live default account
  sleep 14; printf 'live\n'                       # its password
  sleep 14; printf 'echo ===WHOAMI===; id\n'
  sleep 7;  printf 'echo ===BYID===; ls -l /dev/disk/by-id/ | tail -20\n'
  sleep 7;  printf 'echo live | sudo -S mkdir -p /media/carrier\n'
  sleep 7;  printf 'echo live | sudo -S mount /dev/vdb /media/carrier; ls -l /media/carrier\n'
  sleep 10; printf 'echo live | sudo -S install -m 0755 /media/carrier/zfs-stamp.sh /usr/local/sbin/zfs-stamp.sh && echo ===SCRIPTREADY===\n'
  sleep 8;  printf 'echo ===DRYRUN===; echo live | sudo -S /usr/local/sbin/zfs-stamp.sh --profile /media/carrier/mini.conf\n'
  sleep 45; printf 'echo ===APPLY===; echo live | sudo -S /usr/local/sbin/zfs-stamp.sh --profile /media/carrier/mini.conf --apply --yes\n'
  # Diagnostics for the one wart that survives: `zpool export` refuses in the live environment.
  # Everything mount-related is fixed (the "still mounted" warning is gone), so if the export
  # still fails, this dump is what says what is actually holding the pool.
  sleep 60; printf 'echo ===DIAG===; for c in "zpool status -x" "zfs get -H -o name,mounted,mountpoint -r rpool" "zpool events -H" "dmesg | tail -25" "zpool export rpool"; do echo "--- $c"; echo live | sudo -S sh -c "$c" 2>&1 | tail -10; done; echo ===DIAGDONE===\n'
) >&3 2>/dev/null &

# Wait for the run to finish rather than sleeping a fixed amount.
deadline=$(( SECONDS + 1500 ))
while (( SECONDS < deadline )); do
  if grep -qaE "installed '[^']+' onto|^\[fail\]|zfs-stamp.sh: (command )?not found|No such file or directory" "$SCRATCH/installer.log"; then break; fi
  kill -0 "$QPID" 2>/dev/null || break
  sleep 5
done
sleep 10
printf 'quit\n' >&4
for _ in $(seq 1 20); do kill -0 "$QPID" 2>/dev/null || break; sleep 1; done
kill "$QPID" 2>/dev/null; kill "$CATPID" 2>/dev/null; wait "$QPID" 2>/dev/null

echo "=== console markers ==="
grep -aoE "===WHOAMI===|===BYID===|===SCRIPTREADY===|===DRYRUN===|===APPLY===|===DIAG===|===DIAGDONE===|uid=[0-9]+|Plan for|\[ ok \]|\[warn\]|\[fail\]|installed '[^']+' onto|Welcome to Debian|login:" \
  "$SCRATCH/installer.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tail -60
echo "=== verification section ==="
tr -d '\000' < "$SCRATCH/installer.log" | sed 's/\x1b\[[0-9;]*m//g' \
  | sed -n '/Verifying the target can actually boot/,/^$/p' | head -40
echo "=== tail ==="
tail -c 800 "$SCRATCH/installer.log" 2>/dev/null | tr -d '\000' | tail -12

if grep -qa "installed '[^']*' onto" "$SCRATCH/installer.log"; then
  echo "RESULT: PASS — the installer stamped the target."
  exit 0
fi
echo "RESULT: FAIL — the installer did not complete."
exit 1
