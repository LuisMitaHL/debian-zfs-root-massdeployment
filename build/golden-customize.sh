#!/bin/sh
# golden-customize.sh — mmdebstrap --customize-hook for the golden image.
#
# Runs on the build host (inside the Debian container), with the target root as $1.
# TODO-VALIDATE: confirm the exact mmdebstrap hook invocation — some versions pass the target
# as $1 and run outside the chroot, others offer in-chroot hook variants.
#
# Responsibilities:
#   1. add trixie-backports, install ZFS from it
#   2. disable hibernation unconditionally (DESIGN.md §8.1)
#   3. install the identity-sealing unit (DESIGN.md §11)
#   4. enable the services the design depends on
#   5. generate the es_BO.UTF-8 locale and make it the default

set -eu

TARGET="$1"
ROOT="chroot $TARGET"

echo "==> golden-customize: adding trixie-backports"
cat > "$TARGET/etc/apt/sources.list.d/backports.list" <<'EOF'
deb http://deb.debian.org/debian trixie-backports main contrib
EOF

# The build host must resolve DNS for apt; a container on Arch may need this.
cp /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>/dev/null || true

echo "==> golden-customize: installing ZFS from trixie-backports (DKMS builds against 6.12)"
$ROOT apt-get update
$ROOT env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends -t trixie-backports \
    zfsutils-linux zfs-initramfs zfs-zed zfs-dkms

echo "==> golden-customize: verifying the module was actually built"
# DKMS installs to lib/modules/<kver>/updates/dkms/, NOT the in-tree kernel/zfs/ path.
# Search both, and both /lib and /usr/lib because of usr-merge.
zfs_ko="$(find "$TARGET/lib/modules" "$TARGET/usr/lib/modules" \
            -name 'zfs.ko*' -print -quit 2>/dev/null || true)"
if [ -z "$zfs_ko" ]; then
  echo "ERROR: no zfs.ko anywhere in the image — DKMS did not build." >&2
  echo "       On first boot this would leave an unbootable machine." >&2
  exit 1
fi
echo "    found: ${zfs_ko#"$TARGET"}"

echo "==> golden-customize: disabling hibernation unconditionally"
mkdir -p "$TARGET/etc/systemd/sleep.conf.d"
cat > "$TARGET/etc/systemd/sleep.conf.d/10-no-hibernate.conf" <<'EOF'
[Sleep]
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF

echo "==> golden-customize: kernel command line"
mkdir -p "$TARGET/etc/default/grub.d"
# nohibernate goes in GRUB_CMDLINE_LINUX_DEFAULT ONLY. grub-mkconfig puts both
# GRUB_CMDLINE_LINUX and GRUB_CMDLINE_LINUX_DEFAULT on the kernel line, so listing it twice
# just produced `... ro nohibernate quiet nohibernate`. Per-machine parameters (serial
# console, zswap) are appended by zfs-stamp.sh into /etc/default/grub.d/99-zfs-stamp.cfg.
cat > "$TARGET/etc/default/grub.d/99-zfs-root.cfg" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT nohibernate"
GRUB_ENABLE_CRYPTODISK=y
EOF

echo "==> golden-customize: zswap on the kernel command line (mini PCs)"
mkdir -p "$TARGET/etc/default"
cat > "$TARGET/etc/default/zfs-stamp-cmdline" <<'EOF'
# Appended by zfs-stamp.sh, but only for machines with a swap device (the mini class).
#
# zswap is NOT on by default in Debian's kernel (CONFIG_ZSWAP_DEFAULT_ON is not set), so
# zswap.enabled=1 is required.
#
# NO zswap.compressor HERE, deliberately. zswap is initialised during early boot, before any
# module can be loaded, and Debian builds every non-default compressor as a module
# (CONFIG_CRYPTO_ZSTD=m). Asking for zstd therefore does nothing except print
#     zswap: compressor zstd not available, using default lzo
# on every boot. The kernel default is lzo (CONFIG_ZSWAP_COMPRESSOR_DEFAULT="lzo"), which is
# what actually gets used. To get zstd you would have to leave zswap off on the command line,
# load the crypto modules from the initramfs, and then write to
# /sys/module/zswap/parameters/enabled — not worth it for the marginal gain.
zswap.enabled=1
EOF

echo "==> golden-customize: generating the es_BO.UTF-8 locale"
# `locales` is in golden-packages.list, but a fresh mmdebstrap root only has C.UTF-8
# until a locale is generated. Uncomment (or append) the entry, generate just that
# locale, and make it the system default.
if grep -q '^[#[:space:]]*es_BO\.UTF-8 UTF-8' "$TARGET/etc/locale.gen"; then
  sed -i 's/^[#[:space:]]*es_BO\.UTF-8 UTF-8/es_BO.UTF-8 UTF-8/' "$TARGET/etc/locale.gen"
else
  printf '%s\n' 'es_BO.UTF-8 UTF-8' >> "$TARGET/etc/locale.gen"
fi
$ROOT locale-gen es_BO.UTF-8
cat > "$TARGET/etc/default/locale" <<'EOF'
LANG=es_BO.UTF-8
EOF

echo "==> golden-customize: installing the identity-sealing unit"
: "${REPO_DIR:?REPO_DIR must point at the repository}"
install -m 0755 "$REPO_DIR/scripts/seal-identity.sh" "$TARGET/usr/local/sbin/seal-identity.sh"
install -m 0644 "$REPO_DIR/systemd/zfs-stamp-seal.service" \
  "$TARGET/etc/systemd/system/zfs-stamp-seal.service"

echo "==> golden-customize: enabling services"
$ROOT systemctl enable zfs-import-cache.service zfs-mount.service zfs-zed.service || true
$ROOT systemctl enable zfs-stamp-seal.service
$ROOT systemctl enable systemd-networkd.service || true
$ROOT systemctl enable unattended-upgrades.service || true
$ROOT systemctl set-default multi-user.target

echo "==> golden-customize: identity must NOT be baked in"
: > "$TARGET/etc/machine-id"
rm -f "$TARGET/etc/ssh/ssh_host_"*
rm -f "$TARGET/etc/dropbear/dropbear_"*_host_key
rm -f "$TARGET/etc/dropbear/initramfs/dropbear_"*_host_key
rm -f "$TARGET/etc/hostid"

echo "==> golden-customize: done"
