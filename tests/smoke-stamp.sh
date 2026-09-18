#!/usr/bin/env bash
# smoke-stamp.sh — end-to-end smoke test of the golden-image + stamping pipeline.
#
# Run this INSIDE a throwaway Debian 13 VM as root. It never touches real hardware: the
# "target disks" are sparse files attached to loop devices.
#
#   incus launch images:debian/13 zfstest --vm
#   incus file push -r . zfstest/repo
#   incus exec zfstest -- bash /repo/tests/smoke-stamp.sh
#
# What it validates that a lint cannot:
#   * trixie-backports ZFS actually compiles via DKMS against the stock kernel
#   * sgdisk partitioning + mdadm RAID1 /boot + LUKS2 + zpool create + zfs recv
#   * fstab/crypttab generation and the chroot (update-initramfs, grub-install, efibootmgr)
#
# Sizes are deliberately small; override with DISK_SIZE / IMG_SIZE / WORK.

set -Eeuo pipefail

REPO="${REPO:-/repo}"
WORK="${WORK:-/var/tmp/smoke}"
DISK_SIZE="${DISK_SIZE:-4G}"
IMG_SIZE="${IMG_SIZE:-6G}"
N_DISKS="${N_DISKS:-2}"
SUITE="trixie"

PASS=0; FAIL=0
declare -a RESULTS=()
pass() { RESULTS+=("PASS  $1"); PASS=$((PASS+1)); }
fail() { RESULTS+=("FAIL  $1"); FAIL=$((FAIL+1)); }
step() { printf '\n\033[34m=== %s ===\033[0m\n' "$*" >&2; }
note() { printf '[smoke] %s\n' "$*" >&2; }
die()  { printf '[smoke] FATAL: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------- preconditions

step "Preconditions"
[[ "$(id -u)" -eq 0 ]] || die "run as root inside the VM"
[[ -r "$REPO/scripts/zfs-stamp.sh" ]] || die "repo not found at $REPO (set REPO=)"
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "expected Debian, got ${ID:-unknown}"
note "distro ${PRETTY_NAME:-?}, kernel $(uname -r)"

# Make the test re-runnable: a previous failed run can leave an imported pool (which would
# make the next run abort at "a pool named rpool already exists") and stray loop devices.
step "Clearing leftovers from any previous run"
for _ in 1 2 3; do
  umount -R /mnt/target 2>/dev/null || true
  umount -R "$WORK" 2>/dev/null || true
  zfs unmount -a -f 2>/dev/null || true
  zpool destroy -f rpool 2>/dev/null || true
  mdadm --stop /dev/md0 2>/dev/null || true
  [[ -e /dev/md0 ]] || break
  sleep 1
done
losetup -D 2>/dev/null || true
rm -f /dev/disk/by-id/smoke-disk* 2>/dev/null || true
if [[ "${SKIP_GOLDEN:-0}" -eq 1 && -f "$WORK/out/rpool.stream.zst" ]]; then
  note "SKIP_GOLDEN=1 — keeping the existing golden artifacts"
  find "$WORK" -mindepth 1 -maxdepth 1 ! -name out -exec rm -rf {} + 2>/dev/null || true
else
  rm -rf "$WORK"
fi

mkdir -p "$WORK"
avail_gb="$(df -BG --output=avail "$WORK" | tail -1 | tr -dc '0-9')"
note "${avail_gb}G free under $WORK"
(( avail_gb >= 16 )) || die "need >= 16G free under $WORK, have ${avail_gb}G"

# --------------------------------------------------------------------- tooling

step "Installing tooling (backports ZFS + DKMS — this is the slow part)"
cat > /etc/apt/sources.list.d/backports.list <<EOF
deb http://deb.debian.org/debian ${SUITE}-backports main contrib
EOF
# contrib is required: Debian ships ZFS there and there is no zfs.ko in the stock kernel.
grep -qE '^deb .* main contrib' /etc/apt/sources.list 2>/dev/null || \
  sed -i 's/^\(deb .* main\)$/\1 contrib/' /etc/apt/sources.list

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates mmdebstrap zstd rsync uuid-runtime openssh-client \
  mdadm cryptsetup cryptsetup-initramfs gdisk parted dosfstools \
  grub-efi-amd64-bin grub-pc-bin "linux-headers-$(uname -r)" || \
  apt-get install -y -qq --no-install-recommends linux-headers-amd64

apt-get install -y -qq --no-install-recommends -t "${SUITE}-backports" \
  zfs-dkms zfsutils-linux zfs-initramfs

if ls /lib/modules/"$(uname -r)"/kernel/zfs/zfs.ko* >/dev/null 2>&1 \
   || modprobe zfs 2>/dev/null; then
  pass "backports ZFS built and loaded via DKMS ($(zfs --version | head -1))"
else
  fail "DKMS did not produce a loadable zfs.ko — the whole premise is broken"
fi

# --------------------------------------------------------------------- fake target disks

step "Creating $N_DISKS fake target disk(s) of $DISK_SIZE"
LOOPS=()
for (( i=0; i<N_DISKS; i++ )); do
  img="$WORK/disk${i}.img"
  [[ -f "$img" ]] || truncate -s "$DISK_SIZE" "$img"
  dev="$(losetup -f --show -P "$img")"
  LOOPS+=("$dev")
  ln -sf "$dev" "/dev/disk/by-id/smoke-disk${i}"
  note "disk$i -> $dev"
done
pass "attached ${#LOOPS[@]} loop devices with by-id aliases"
cleanup_test() {
  local d i
  if [[ "${KEEP_TARGET:-0}" -eq 1 ]]; then
    note "KEEP_TARGET=1 — leaving the target mounted and the pool imported for inspection"
    return
  fi
  # Tear down in dependency order and retry: a failure mid-run can leave mounts behind that
  # make mdadm refuse to stop the array, which then poisons the next run.
  for i in 1 2 3; do
    umount -R /mnt/target 2>/dev/null || true
    umount -R "$WORK" 2>/dev/null || true
    zfs unmount -a -f 2>/dev/null || true
    zpool destroy -f rpool 2>/dev/null || true
    mdadm --stop /dev/md0 2>/dev/null || true
    [[ -e /dev/md0 ]] || break
    sleep 1
  done
  for d in "${LOOPS[@]:-}"; do losetup -d "$d" 2>/dev/null || true; done
}
trap cleanup_test EXIT

# --------------------------------------------------------------------- golden image

step "Building the golden image (build-golden.sh --native)"
export OUT="$WORK/out" IMG_SIZE GOLDEN_WORK="$WORK/golden"
if [[ "${SKIP_GOLDEN:-0}" -eq 1 && -f "$OUT/rpool.stream.zst" && -f "$OUT/boot.tar.zst" ]]; then
  pass "reusing the existing golden image (SKIP_GOLDEN=1)"
elif "$REPO/build/build-golden.sh" --native --clean >"$WORK/golden.log" 2>&1; then
  pass "golden image built (build-golden.sh --native)"
else
  fail "golden build failed — see $WORK/golden.log"
  tail -25 "$WORK/golden.log" >&2
  printf '\n%s\n' "${RESULTS[@]}" >&2
  exit 1
fi

# --------------------------------------------------------------------- carrier

step "Staging the carrier medium layout"
mkdir -p /media/carrier
cp "$OUT/rpool.stream.zst" /media/carrier/rpool.stream.zst
cp "$OUT/boot.tar.zst"     /media/carrier/boot.tar.zst
# crypttab(5): "the entire key file will be used as the passphrase; the passphrase must not be
# followed by a newline character" — so write it with no trailing newline.
printf 'smoke-test-passphrase' > "$WORK/luks.key"
chmod 600 "$WORK/luks.key"
# dropbear-initramfs refuses remote logins without an authorized_keys file, so the profile
# must point at one. Generate a throwaway key for the test.
rm -f "$WORK/dropbear_key" "$WORK/dropbear_key.pub"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/dropbear_key"
# Same for the login user: separate throwaway key plus a pre-hashed password.
rm -f "$WORK/user_key" "$WORK/user_key.pub"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/user_key"
USER_HASH="$(openssl passwd -6 -salt smokesalt smoke-test-password)"
pass "carrier staged at /media/carrier"

# --------------------------------------------------------------------- profile

step "Writing the smoke profile"
cat > "$WORK/smoke.conf" <<EOF
PROFILE_NAME="smoke"
CLASS="server"
HOSTNAME="smoke01"
DISKS=(
$(for (( i=0; i<N_DISKS; i++ )); do printf '  /dev/disk/by-id/smoke-disk%s\n' "$i"; done)
)
TOPOLOGY="mirror"
BOOT_MODE="uefi"
SWAP="none"
ZRAM="yes"
CRYPT="yes"
LUKS_KEYFILE="$WORK/luks.key"
DROPBEAR_AUTHORIZED_KEYS="$WORK/dropbear_key.pub"
USERNAME="smokeuser"
USER_PASSWORD_HASH="$USER_HASH"
USER_AUTHORIZED_KEYS="$WORK/user_key.pub"
ADDRESS="dhcp"
SERIAL_CONSOLE="ttyS0,115200"
EOF

# --------------------------------------------------------------------- dry run

step "Dry run (must not write anything)"
if "$REPO/scripts/zfs-stamp.sh" --profile "$WORK/smoke.conf" >"$WORK/dryrun.log" 2>&1; then
  pass "dry run completed"
else
  fail "dry run failed — see $WORK/dryrun.log"
  tail -20 "$WORK/dryrun.log" >&2
fi

# --------------------------------------------------------------------- apply

step "Applying (this is the real end-to-end test)"
if "$REPO/scripts/zfs-stamp.sh" --profile "$WORK/smoke.conf" --apply --yes \
     >"$WORK/apply.log" 2>&1; then
  pass "zfs-stamp.sh --apply completed"
else
  fail "zfs-stamp.sh --apply failed — see $WORK/apply.log"
  tail -30 "$WORK/apply.log" >&2
fi

# --------------------------------------------------------------------- assertions

step "Assertions on the stamped, finished result"

# zfs-stamp.sh ends by exporting the pool and closing the containers. Verify THAT state first:
# it is what the firmware and initramfs will actually see.
if ! zpool list -H -o name 2>/dev/null | grep -qx rpool; then
  pass "pool is exported (not left imported under the live altroot)"
else
  fail "pool is still imported — altroot would confuse the first boot"
fi
if ! cryptsetup status zfs0 >/dev/null 2>&1; then
  pass "LUKS containers are closed"
else
  fail "LUKS container is still open"
fi

# Rehearse the boot: open the containers and import the pool exactly as the initramfs will.
mkdir -p /mnt/check
# Derive the partition paths from the loop devices we actually attached. Hardcoding
# /dev/loop0p3 works until some other loop device already holds loop0, and then the failure is
# baffling. LOOP_ALIAS names the by-id alias used in the profile, which is also the prefix the
# stamp script writes into crypttab.
LOOP_ALIAS=()
for (( i=0; i<N_DISKS; i++ )); do
  LOOP_ALIAS+=("/dev/disk/by-id/smoke-disk${i}")
  cryptsetup open --key-file "$WORK/luks.key" "${LOOPS[$i]}p3" "zfs${i}" 2>/dev/null || true
done
if zpool import -N -R /mnt/check -f rpool 2>/dev/null; then
  pass "pool imports cleanly from the stamped disks"
else
  fail "pool could not be imported from the stamped disks"
fi

if zpool status rpool 2>/dev/null | grep -q mirror; then
  pass "rpool is a mirror"
else
  fail "rpool is not a mirror"
fi
if zfs list -H -o name rpool/ROOT/debian >/dev/null 2>&1; then
  pass "rpool/ROOT/debian is present"
else
  fail "rpool/ROOT/debian missing"
fi
bf="$(zpool get -H -o value bootfs rpool 2>/dev/null || true)"
if [[ "$bf" == "rpool/ROOT/debian" ]]; then
  pass "bootfs is set ($bf)"
else
  fail "bootfs is '$bf'"
fi

# The final layout stage_finish must leave behind. mountpoint=/ is not cosmetic: the initramfs
# mounts bootfs with `mount -o zfsutil` and mount.zfs REFUSES when the requested target does not
# match this property ("canonicalization error"), dropping the machine to an (initramfs) shell.
# During staging it is /mnt/target, so this only holds after stage_finish has run.
root_mp="$(zfs get -H -o value mountpoint rpool/ROOT/debian 2>/dev/null || true)"
root_cm="$(zfs get -H -o value canmount  rpool/ROOT/debian 2>/dev/null || true)"
if [[ "$root_mp" == "/" && "$root_cm" == "noauto" ]]; then
  pass "root dataset final layout is mountpoint=/ canmount=noauto"
else
  fail "root dataset is mountpoint='$root_mp' canmount='$root_cm' (want / and noauto)"
fi

# -R here is an IMPORT-TIME altroot, purely so this inspection mounts the tree at /mnt/check
# instead of over the VM's own root (the dataset's mountpoint really is /). It is not persisted,
# unlike the `zpool create -R` the design deliberately dropped.
zfs mount rpool/ROOT/debian 2>/dev/null || true
if grep -qE "^zfs0 UUID=" /mnt/check/etc/crypttab 2>/dev/null \
   && grep -qE "^zfs1 UUID=" /mnt/check/etc/crypttab 2>/dev/null; then
  pass "crypttab identifies containers by LUKS UUID (device-name independent)"
else
  fail "crypttab does not use UUID= — boot would depend on unstable device names"
fi

# Login user from the profile: exists, in sudo, key installed, password set.
if grep -qE '^smokeuser:x:[0-9]+:[0-9]+:' /mnt/check/etc/passwd 2>/dev/null; then
  pass "login user smokeuser exists"
else
  fail "login user smokeuser missing from the target passwd"
fi
if grep -qE '^sudo:[^:]*:[^:]*:.*smokeuser' /mnt/check/etc/group 2>/dev/null; then
  pass "smokeuser is in the sudo group"
else
  fail "smokeuser is not in sudo (is sudo in golden-packages.list?)"
fi
if [[ -s /mnt/check/home/smokeuser/.ssh/authorized_keys ]] \
   && grep -q "$(cut -d' ' -f2 "$WORK/user_key.pub")" \
     /mnt/check/home/smokeuser/.ssh/authorized_keys; then
  pass "smokeuser authorized_keys installed"
else
  fail "smokeuser authorized_keys missing or wrong"
fi
smoke_pw="$(grep -E '^smokeuser:' /mnt/check/etc/shadow 2>/dev/null | cut -d: -f2)"
if [[ "$smoke_pw" == '$6$smokesalt$'* ]]; then
  pass "smokeuser password hash applied"
else
  fail "smokeuser password hash missing (shadow field: '${smoke_pw:0:12}...')"
fi

# /boot lives on the md array; assemble and mount it so the initramfs can be inspected.
MD_PARTS=()
for d in "${LOOPS[@]}"; do MD_PARTS+=("${d}p2"); done
mdadm --assemble /dev/md0 "${MD_PARTS[@]}" >/dev/null 2>&1 || true
mkdir -p /mnt/check/boot
mount /dev/md0 /mnt/check/boot 2>/dev/null || true
if mdadm --detail /dev/md0 2>/dev/null | grep -q raid1; then
  pass "mdadm /boot array is RAID1"
else
  fail "mdadm /boot array missing or wrong level"
fi

# --------------------------------------------------------------------- boot-critical config
#
# These four checks are the ones that would have caught the bugs that stopped the first stamped
# machine from booting. All of them are cheap, and all of them fail *silently* without a check.

# 1. GRUB must have a MENU. `grub-install` only lays down modules and a grubenv; it does not
#    write grub.cfg. Without update-grub the target boots to the `grub>` prompt.
if [[ -s /mnt/check/boot/grub/grub.cfg ]] \
   && grep -q "root=ZFS=rpool/ROOT/debian" /mnt/check/boot/grub/grub.cfg; then
  pass "grub.cfg exists and names root=ZFS=rpool/ROOT/debian"
else
  fail "no usable /boot/grub/grub.cfg — the machine would not boot (missing update-grub?)"
fi

# 2. The command line. nohibernate is a hard requirement (DESIGN.md §8.1); console=ttyS0 is what
#    makes a headless machine (and this test) observable.
if grep -qs 'nohibernate' /mnt/check/boot/grub/grub.cfg; then
  pass "kernel command line carries nohibernate"
else
  fail "nohibernate missing from the kernel command line"
fi
if grep -qs 'console=ttyS0,115200' /mnt/check/boot/grub/grub.cfg; then
  pass "kernel command line carries console=ttyS0,115200"
else
  fail "SERIAL_CONSOLE was set but is not on the kernel command line"
fi

# 3. /etc/crypttab is inert without systemd-cryptsetup: Debian masks cryptdisks.service, and
#    systemd-cryptsetup is only a Recommends of systemd (dropped by --variant=important). The
#    symptom is a ~90s boot stall on dev-mapper-swap.device and no ephemeral swap.
if [[ -x /mnt/check/usr/lib/systemd/system-generators/systemd-cryptsetup-generator ]]; then
  pass "systemd-cryptsetup-generator present (crypttab is honoured at boot)"
else
  fail "systemd-cryptsetup missing — /etc/crypttab would be inert (add it to golden-packages.list)"
fi

# 4. Memory config must match the class. The generator ships a default [zram0], so a config that
#    is absent (or a percentage zram-size) silently gives the wrong swap setup.
if grep -qE '^\[zram0\]' /mnt/check/etc/systemd/zram-generator.conf 2>/dev/null; then
  if grep -qE '^zram-size[[:space:]]*=[[:space:]]*[0-9]+%' /mnt/check/etc/systemd/zram-generator.conf; then
    fail "zram-size is a percentage — zram-generator needs an expression like 'ram / 2'"
  else
    pass "zram0 configured for the server class"
  fi
else
  fail "ZRAM=yes but no [zram0] section — the server would boot with no swap at all"
fi

# The initramfs must actually contain cryptsetup and dropbear, or the machine cannot be
# unlocked remotely on first boot — the entire unlock design depends on it.
initrd=""
for f in /mnt/check/boot/initrd.img-*; do
  if [[ -e "$f" ]]; then initrd="$f"; break; fi
done
if [[ -n "$initrd" ]]; then
  note "inspecting $initrd ($(stat -c%s "$initrd") bytes)"
  # Capture the listing ONCE. Piping into `grep -q` would break under `set -o pipefail`:
  # grep -q exits on first match, lsinitramfs takes SIGPIPE, and the pipeline reports 141.
  listing="$(lsinitramfs "$initrd" 2>/dev/null || true)"
  note "initrd entries mentioning crypt/dropbear: $(grep -icE 'cryptsetup|dropbear' <<<"$listing")"
  if grep -q cryptsetup <<<"$listing"; then
    pass "initramfs contains cryptsetup"
  else
    fail "initramfs has no cryptsetup — LUKS unlock at boot would fail"
  fi
  if grep -q dropbear <<<"$listing"; then
    pass "initramfs contains dropbear (remote unlock possible)"
  else
    fail "initramfs has no dropbear — remote unlock would fail"
  fi
else
  fail "no initramfs found in the target /boot"
fi

# --------------------------------------------------------------------- report

step "Summary"
printf '%s\n' "${RESULTS[@]}" >&2
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL" >&2
printf 'Logs: %s/{golden,dryrun,apply}.log\n' "$WORK" >&2
(( FAIL == 0 )) || exit 1
printf '\nSMOKE TEST PASSED\n' >&2
