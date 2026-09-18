#!/usr/bin/env bash
# build-live.sh — build the Debian live installer medium (USB image + PXE netboot payload).
#
# The live medium carries: a Debian trixie environment with ZFS available, the stamping
# scripts, and the per-host profiles. It does NOT carry the golden stream — that lives on a
# separate partition of the same USB (see README.md), so the ISO does not need rebuilding
# every time the golden image changes.
#
#   ./build/build-live.sh
#
# Outputs (in $OUT):
#   debian-zfs-installer.iso        hybrid image, write to USB with dd
#   netboot.tar.gz                  tftpboot/ for PXE
#
# STATUS: first draft, never executed. live-build needs privileged loop/mount access —
# run build/verify-host.sh first. TODO-VALIDATE: confirm --bootloaders and netboot flag names
# against trixie's live-build; the Live Manual's --net-root-* flags are stale.

set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$REPO/out}"
LBWORK="${LBWORK:-$OUT/live-build}"
# live-build caches downloaded .debs and apt indices under <build>/cache. The build itself runs
# on the container's filesystem (see below), so that cache would die with the container. This
# host directory is bind-mounted over it to persist the cache between runs. It holds only
# regular files, so the host's `nodev` mount is irrelevant here.
CACHE_DIR="${CACHE_DIR:-$OUT/lb-cache}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-debian:trixie}"
LOOP_PROBE_IMAGE="${LOOP_PROBE_IMAGE:-alpine}"
SUITE="trixie"

log()  { printf '[build-live] %s\n' "$*" >&2; }
warn() { printf "[build-live] WARN: %s\n" "$*" >&2; }
die()  { printf "[build-live] ERROR: %s\n" "$*" >&2; exit 1; }
stage(){ printf '\n== %s ==\n' "$*" >&2; }

# live-build assembles the ISO inside a privileged container, so the loop-device probe must run
# THERE too: checking /dev of this shell's namespace gives a false negative inside a sandbox.
probe_loop_in_container() {
  # Single quotes are deliberate: $D must expand inside the container, not on the host.
  # shellcheck disable=SC2016
  timeout 180 docker run --rm --privileged "$LOOP_PROBE_IMAGE" sh -c '
    dd if=/dev/zero of=/tmp/probe bs=1M count=8 2>/dev/null || exit 1
    D=$(losetup -f 2>/dev/null) || exit 1
    [ -n "$D" ] || exit 1
    losetup "$D" /tmp/probe 2>/dev/null || exit 1
    losetup -d "$D" 2>/dev/null || exit 1
  ' >/dev/null 2>&1
}

stage "Preflight"
command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "docker daemon not reachable"
probe_loop_in_container \
  || die "a privileged container cannot attach a loop device — ISO assembly would fail"
log "loop devices are available inside a privileged container"

mkdir -p "$OUT"
avail_gb="$(df -BG --output=avail "$OUT" | tail -1 | tr -dc '0-9')"
(( avail_gb >= 10 )) || die "need >= 10G free under $OUT, have ${avail_gb}G"
log "${avail_gb}G free under $OUT"

# --------------------------------------------------------------------- live-build config tree

stage "Preparing the live-build config tree at $LBWORK"
rm -rf "$LBWORK"
mkdir -p "$LBWORK/config/package-lists" \
         "$LBWORK/config/includes.chroot/usr/local/sbin" \
         "$LBWORK/config/includes.chroot/etc/zfs-stamp/profiles" \
         "$LBWORK/config/archives" \
         "$LBWORK/config/hooks/normal"

# ZFS is in contrib, which the official Debian live images deliberately exclude.
cat > "$LBWORK/config/package-lists/zfs.list.chroot" <<'EOF'
# NOTE: the ZFS packages and the DKMS toolchain are deliberately NOT listed here. They are
# installed by the hook below, which runs AFTER the main package set is configured. Reason:
# live-build always pulls in shim-signed for UEFI, and shim-signed's postinst fails if a DKMS
# MOK key already exists but is not enrolled ("System's DKMS key is NOT installed in MOK").
# Installing zfs-dkms later means no MOK key exists while shim-signed configures.
# Bonus: ZFS then comes only from backports (2.4.4) instead of trixie's 2.3.9 first.
linux-image-amd64
mdadm
gdisk
parted
dosfstools
efibootmgr
grub-common
grub-efi-amd64
grub-pc-bin
cryptsetup
cryptsetup-initramfs
zstd
rsync
EOF

cat > "$LBWORK/config/archives/backports.list.chroot" <<'EOF'
deb http://deb.debian.org/debian trixie-backports main contrib
EOF

# The stamping scripts and the profiles travel on the medium.
install -m 0755 "$REPO/scripts/zfs-stamp.sh"      "$LBWORK/config/includes.chroot/usr/local/sbin/zfs-stamp.sh"
install -m 0755 "$REPO/scripts/seal-identity.sh"  "$LBWORK/config/includes.chroot/usr/local/sbin/seal-identity.sh"
install -m 0644 "$REPO"/profiles/*.conf           "$LBWORK/config/includes.chroot/etc/zfs-stamp/profiles/"

# Operator instructions, in BOTH places they can be useful:
#   includes.binary/ -> copied verbatim into the ISO tree, so it is readable by simply mounting
#                       the medium on any machine, including one that cannot boot it.
#   includes.chroot/ -> readable as /root/README.txt inside the live session.
# There is no ROOT of the ISO *filesystem* as seen after boot (the live system runs from a
# squashfs), so the root of the medium is the only place that matches "at the root of the ISO".
mkdir -p "$LBWORK/config/includes.binary" \
         "$LBWORK/config/includes.chroot/root"
install -m 0644 "$REPO/build/iso-readme.txt" "$LBWORK/config/includes.binary/README.txt"
install -m 0644 "$REPO/build/iso-readme.txt" "$LBWORK/config/includes.chroot/root/README.txt"

# ZFS is installed here, after shim-signed has been configured. See the note above.
cat > "$LBWORK/config/hooks/normal/0100-zfs-backports.hook.chroot" <<'EOF'
#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update
# DKMS toolchain: the live kernel's headers are needed to build zfs.ko at image-build time.
apt-get install -y --no-install-recommends dkms build-essential linux-headers-amd64
# ZFS itself, from backports so live and target run the same OpenZFS.
apt-get install -y -t trixie-backports \
  zfsutils-linux zfs-initramfs zfs-zed zfs-dkms
# Fail loudly if the module did not build: the live environment is useless without it.
if ! ls /lib/modules/*/updates/dkms/zfs.ko* >/dev/null 2>&1 \
   && ! find /usr/lib/modules -name 'zfs.ko*' -print -quit 2>/dev/null | grep -q .; then
  echo "ERROR: no zfs.ko built in the live image — the stamping script cannot run" >&2
  exit 1
fi
echo "==> live image ZFS: $(zfs --version | head -1)"
EOF
chmod +x "$LBWORK/config/hooks/normal/0100-zfs-backports.hook.chroot"

# --------------------------------------------------------------------- build

# live-build manipulates device nodes inside its chroot. The build tree therefore must NOT
# live on a bind mount: the host workspace is a btrfs subvolume mounted `nodev`, which makes
# `chroot/dev/null` unusable and every package postinst fail with
# "cannot create /dev/null: Permission denied". So the whole build runs on the container's own
# filesystem and only the finished artifacts are copied out.
stage "Building inside the container (bind-mounted trees are nodev)"
mkdir -p "$CACHE_DIR"
docker run --rm --privileged \
  -v "$LBWORK:/cfg:ro" \
  -v "$OUT:/out" \
  -v "$CACHE_DIR:/lb/cache" \
  -e DEBIAN_FRONTEND=noninteractive \
  "$CONTAINER_IMAGE" \
  bash -euo pipefail -c '
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends live-build ca-certificates

    mkdir -p /lb && cd /lb
    cp -a /cfg/config .

    echo "==> lb config (iso-hybrid)"
    lb config \
      --distribution '"$SUITE"' \
      --archive-areas "main contrib non-free-firmware" \
      --linux-flavours amd64 \
      --linux-packages "linux-image linux-headers" \
      --bootloaders "syslinux,grub-efi" \
      --binary-images iso-hybrid \
      --debian-installer false \
      --firmware-chroot true \
      --memtest none \
      --uefi-secure-boot disable \
      --bootappend-live "boot=live components console=tty0 console=ttyS0,115200"

    # The GRUB config.cfg does `loadfont $font`. Debian GRUB is built with
    # feature_default_font_path, so $font is the *name* "unicode", which GRUB resolves to
    # $prefix/fonts/unicode.pf2 -- while live-build only ships $prefix/unicode.pf2. UEFI boot
    # therefore dies with: error: file /boot/grub/fonts/unicode.pf2 not found.
    # config/includes.binary/ is copied verbatim into the ISO tree, so this lands the font
    # where loadfont actually looks. (A binary-stage hook runs too late to affect the ISO.)
    echo "==> placing the GRUB font where loadfont looks"
    apt-get install -y -qq --no-install-recommends grub-common
    install -D /usr/share/grub/unicode.pf2 \
      config/includes.binary/boot/grub/fonts/unicode.pf2

    echo "==> lb build (iso-hybrid)"
    lb build

    echo "==> collecting the ISO"
    cp live-image-amd64.hybrid.iso /out/debian-zfs-installer.iso

    echo "==> lb config (netboot) + build"
    # netboot images are PXE-only: live-build rejects grub-* bootloaders for netboot,
    # syslinux/pxelinux is the only valid choice there.
    if lb clean --binary \
       && lb config --binary-images netboot --bootloaders syslinux \
       && lb build; then
      gzip -c live-image-amd64.netboot.tar > /out/netboot.tar.gz
      echo "==> netboot payload collected"
    else
      echo "WARNING: netboot build failed (the ISO is still produced)"
    fi
  '

[[ -f "$OUT/debian-zfs-installer.iso" ]] || die "live-build did not produce an ISO (see log above)"
log "wrote $OUT/debian-zfs-installer.iso ($(du -h "$OUT/debian-zfs-installer.iso" | cut -f1))"

if [[ -f "$OUT/netboot.tar.gz" ]]; then
  log "wrote $OUT/netboot.tar.gz ($(du -h "$OUT/netboot.tar.gz" | cut -f1))"
else
  warn "netboot tarball not produced — check the live-build flags (TODO-VALIDATE)"
fi

stage "Done"
cat >&2 <<EOF
  USB image : $OUT/debian-zfs-installer.iso
  PXE       : $OUT/netboot.tar.gz

  Next: write the ISO to the carrier USB and add the golden artifacts on a second
  partition. See README.md.
EOF
