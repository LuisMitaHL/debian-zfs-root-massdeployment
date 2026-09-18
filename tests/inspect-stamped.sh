#!/bin/bash
# Inspect a stamped disk image WITHOUT booting it: assemble the stack (LUKS -> zpool -> mounts)
# read-only style, dump the config that decides whether the machine can boot, then tear down.
#
#   ./inspect-stamped.sh [image] [keyfile]
#
# Defaults to /mnt/scratch/single.img + /mnt/scratch/smoke/luks.key (mini-single, bios).
set -u

IMG="${1:-/mnt/scratch/single.img}"
KEY="${2:-/mnt/scratch/smoke/luks.key}"
POOL="rpool"
MNT="/mnt/inspect"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# Unmount deepest-first with a lazy fallback. cgroup2 under /sys refuses a normal unmount
# (systemd holds it), and one refusal aborts a whole `umount -R` — leaving the dataset busy and
# `zpool export`/`destroy` failing with "pool or dataset is busy". That is the whole of §5.4.
teardown() {
  local m
  while read -r m; do
    [[ -n "$m" ]] || continue
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null
  done < <(awk -v p="$MNT" '$2 ~ ("^" p "(/|$)") { print $2 }' /proc/mounts \
             | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

  zfs unmount -a -f 2>/dev/null

  # Restore the properties the target needs to boot. Inspecting sets mountpoint=$MNT so the
  # golden root can be mounted somewhere harmless; if that is not undone, the initramfs reaches
  # root and then fails with
  #   mount.zfs: filesystem 'rpool/ROOT/debian' cannot be mounted at '/root//mnt/inspect'
  #   due to canonicalization error
  # and drops to an (initramfs) shell. canmount before mountpoint, or it remounts at /.
  if zpool list "$POOL" >/dev/null 2>&1; then
    zfs set canmount=noauto "$POOL/ROOT/debian" 2>/dev/null
    zfs set mountpoint=/ "$POOL/ROOT/debian" 2>/dev/null
    zfs set mountpoint=/home "$POOL/home" 2>/dev/null
    zfs set canmount=on "$POOL/home" 2>/dev/null
  fi

  zpool export "$POOL" 2>/dev/null || zpool destroy -f "$POOL" 2>/dev/null
  for m in /dev/mapper/zfs*; do [[ -e "$m" ]] && cryptsetup close "$(basename "$m")" 2>/dev/null; done
  [[ -e /dev/md0 ]] && mdadm --stop /dev/md0 2>/dev/null
  [[ -n "${LOOP:-}" && -e "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
  return 0
}
trap teardown EXIT

say "attaching $IMG"
LOOP="$(losetup --find --show --partscan "$IMG")"
echo "loop: $LOOP"
sgdisk -p "$LOOP" 2>/dev/null | sed -n '1,20p'
partx -o NR,START,SIZE,TYPE -g "$LOOP" 2>/dev/null | awk '{printf "  part%-3s type=%-6s size=%s\n",$1,$4,$3/2048" MiB"}'
udevadm settle

# The LUKS member is the partition with LUKS on it; find it by probing rather than by index.
LUKS_PART=""
for p in "$LOOP"p*; do
  if cryptsetup isLuks "$p" 2>/dev/null; then LUKS_PART="$p"; break; fi
done
[[ -n "$LUKS_PART" ]] || { echo "no LUKS partition found on $LOOP"; exit 1; }

say "LUKS header ($LUKS_PART)"
cryptsetup luksDump "$LUKS_PART" 2>/dev/null | grep -E "Version|UUID|Label|PBKDF|Cipher|Key|Sector" | head -8

say "opening container with $KEY"
cryptsetup open --key-file "$KEY" "$LUKS_PART" zfs0 || { echo "unlock FAILED"; exit 1; }
echo "opened (key file works)"

say "importing $POOL (no mounts)"
zpool import -N -f "$POOL" || { echo "import FAILED"; exit 1; }
zpool list
zpool get -H altroot bootfs "$POOL"
echo "--- datasets ---"
zfs list -r -o name,used,mountpoint,canmount "$POOL"

say "mounting datasets"
mkdir -p "$MNT"
zfs set mountpoint="$MNT" canmount=noauto "$POOL/ROOT/debian"
zfs mount "$POOL/ROOT/debian"
[[ -d "$MNT/home" ]] && { zfs set mountpoint="$MNT/home" "$POOL/home" 2>/dev/null; zfs mount "$POOL/home" 2>/dev/null; }

# /boot is a plain ext4 partition outside the pool.
BOOT_PART=""
for p in "$LOOP"p*; do
  if [[ "$p" != "$LUKS_PART" ]] && blkid -s TYPE -o value "$p" 2>/dev/null | grep -q ext4; then BOOT_PART="$p"; break; fi
done
if [[ -n "$BOOT_PART" ]]; then
  mount "$BOOT_PART" "$MNT/boot" && echo "/boot mounted from $BOOT_PART"
  # server class: /boot may instead be an mdadm array
fi

say "=== /etc/crypttab ==="
cat "$MNT/etc/crypttab" 2>/dev/null || echo "(missing)"

say "=== /etc/fstab ==="
cat "$MNT/etc/fstab" 2>/dev/null || echo "(missing)"

say "=== CRYPTSETUP conf-hook ==="
cat "$MNT/etc/cryptsetup-initramfs/conf-hook" 2>/dev/null || echo "(missing)"

say "=== /etc/default/grub (cmdline) ==="
grep -E "CMDLINE|TERMINAL|SERIAL" "$MNT/etc/default/grub" 2>/dev/null || echo "(missing)"

say "=== root dataset properties ==="
zfs get -H -o property,value mountpoint,canmount "$POOL/ROOT/debian"

say "=== hostid ==="
ls -l "$MNT/etc/hostid" 2>/dev/null && od -An -tx4 "$MNT/etc/hostid" 2>/dev/null

say "=== initramfs contents (the boot-critical bits) ==="
INITRD="$(ls "$MNT"/boot/initrd.img-* 2>/dev/null | head -1)"
if [[ -n "$INITRD" ]]; then
  echo "initrd: $INITRD"
  listing="$(lsinitramfs "$INITRD" 2>/dev/null)"
  for pat in cryptsetup cryptroot dropbear zfs mdadm; do
    printf '  %-12s %s\n' "$pat" "$(grep -c -- "$pat" <<<"$listing")"
  done
  echo "  --- dropbear/initramfs keys ---"
  grep -E "dropbear.*_host_key|authorized_keys" <<<"$listing"
else
  echo "(no initrd found)"
fi

say "=== /boot contents ==="
ls -lh "$MNT/boot" 2>/dev/null | head

say "=== ESP contents ==="
ESP_PART=""
for p in "$LOOP"p*; do
  if blkid -s TYPE -o value "$p" 2>/dev/null | grep -qi vfat; then ESP_PART="$p"; break; fi
done
if [[ -n "$ESP_PART" ]]; then
  mkdir -p "$MNT/boot/efi"
  if mount "$ESP_PART" "$MNT/boot/efi"; then
    find "$MNT/boot/efi" -maxdepth 4 | head -20
    umount "$MNT/boot/efi"
  fi
else
  echo "(no ESP — bios-only image?)"
fi

say "=== GRUB config: the default menu entry ==="
grubcfg="$MNT/boot/grub/grub.cfg"
if [[ -r "$grubcfg" ]]; then
  grep -nE "^\s*(menuentry|linux|initrd|set root|search)" "$grubcfg" | head -20
else
  echo "(no $grubcfg)"
fi

say "done — tearing down"
