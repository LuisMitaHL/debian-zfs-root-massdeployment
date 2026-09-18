#!/usr/bin/env bash
# zfs-stamp.sh — stamp a golden Debian 13 root-on-ZFS image onto a target machine.
#
# Runs from the Debian live install environment (the custom live-build medium), NOT from the
# installed system. Destroys the partition tables of every disk named in the profile.
#
#   ./zfs-stamp.sh --profile profiles/server-mirror.conf              # dry run (default)
#   ./zfs-stamp.sh --profile profiles/server-mirror.conf --apply      # actually do it
#
# Safety model:
#   * dry-run is the DEFAULT; nothing is written without --apply
#   * disks must be /dev/disk/by-id/* and must exist
#   * the resolved device list is printed and must be confirmed (unless --yes)
#
# STATUS: first draft, never executed. Stages marked TODO-VALIDATE need a scratch VM.

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"

# --------------------------------------------------------------------------- defaults

POOL="rpool"
ESP_SIZE="1G"
BOOT_SIZE="2G"
BIOS_SIZE="1M"
CRYPT="yes"
ZSWAP="no"
ZRAM="no"
# An EXPRESSION in MiB as a function of MemTotal — `ram / 2`, `min(ram / 2, 4096)`. NOT a
# percentage: zram-generator rejects "50%" and then creates no device at all.
ZRAM_SIZE="ram / 2"
SWAP=""
SWAP_SIZE="4G"
ADDRESS="dhcp"
IPV4=""; CIDR=""; GATEWAY=""; DNS=""
# Serial console for headless machines, e.g. "ttyS0,115200". Empty = VGA only.
# Normalised to "ttyS<N>,<speed>" by validate_profile; SERIAL_UNIT/SERIAL_SPEED feed GRUB.
SERIAL_CONSOLE=""
SERIAL_UNIT=""
SERIAL_SPEED=""
LUKS_KEYFILE=""
DROPBEAR_AUTHORIZED_KEYS=""
# Optional login user with sudo (empty USERNAME = root-only, as before).
USERNAME=""
USER_PASSWORD_HASH=""
USER_AUTHORIZED_KEYS=""
USER_SHELL="/bin/bash"
CRYPTTAB_LINES=()
GOLDEN_STREAM="/media/carrier/rpool.stream.zst"
BOOT_PAYLOAD="/media/carrier/boot.tar.zst"
MNT="/mnt/target"

APPLY=0
ASSUME_YES=0
PROFILE_FILE=""

# --------------------------------------------------------------------------- logging

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_blu=$'\033[34m'
log()  { printf '%s[%s]%s %s\n' "$c_blu" "$SCRIPT_NAME" "$c_reset" "$*" >&2; }
ok()   { printf '%s[ ok ]%s %s\n' "$c_grn" "$c_reset" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$c_yel" "$c_reset" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }
stage(){ printf '\n%s==> %s%s\n' "$c_blu" "$*" "$c_reset" >&2; }

run() {
  if (( APPLY )); then
    log "RUN: $*"
    "$@"
  else
    printf '  would run: %s\n' "$*" >&2
  fi
}

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME --profile <file> [--apply] [--yes]

  --profile <file>   per-host profile to stamp (see profiles/README.md)
  --apply            perform the installation (default: dry run)
  --yes              skip the interactive disk confirmation
  -h, --help         this text
EOF
  exit 1
}

# --------------------------------------------------------------------------- args

while (( $# )); do
  case "$1" in
    --profile) PROFILE_FILE="${2:-}"; shift 2 ;;
    --apply)   APPLY=1; shift ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$PROFILE_FILE" ]] || usage
[[ -r "$PROFILE_FILE" ]] || die "profile not readable: $PROFILE_FILE"

# --------------------------------------------------------------------------- load profile

# shellcheck disable=SC1090
. "$PROFILE_FILE"

: "${PROFILE_NAME:?profile must set PROFILE_NAME}"
: "${CLASS:?profile must set CLASS}"
: "${HOSTNAME:?profile must set HOSTNAME}"
: "${TOPOLOGY:?profile must set TOPOLOGY}"
: "${BOOT_MODE:?profile must set BOOT_MODE}"
[[ ${#DISKS[@]} -gt 0 ]] || die "profile must set DISKS"

# class-dependent defaults
if [[ "$CLASS" == "mini" ]]; then
  [[ -z "$SWAP" ]] && SWAP="ephemeral"
  [[ "$ZSWAP" == "no" && "$ZRAM" == "no" ]] && ZSWAP="yes"
else
  [[ -z "$SWAP" ]] && SWAP="none"
  [[ "$ZSWAP" == "no" && "$ZRAM" == "no" ]] && ZRAM="yes"
fi
[[ -n "${BOOT_DISKS:-}" ]] || BOOT_DISKS=("${DISKS[@]}")

# --------------------------------------------------------------------------- validate

validate_profile() {
  stage "Validating profile '$PROFILE_NAME'"

  case "$CLASS" in mini|server) ;; *) die "CLASS must be 'mini' or 'server'"; esac
  case "$TOPOLOGY" in single|mirror|raidz1|raidz2|raidz3) ;; *) die "bad TOPOLOGY: $TOPOLOGY";; esac
  case "$BOOT_MODE" in uefi|bios|both) ;; *) die "bad BOOT_MODE: $BOOT_MODE";; esac
  case "$CRYPT" in yes|no) ;; *) die "CRYPT must be yes/no";; esac
  case "$SWAP" in none|ephemeral) ;; *) die "SWAP must be none/ephemeral";; esac
  case "$ADDRESS" in dhcp|static) ;; *) die "ADDRESS must be dhcp/static";; esac

  # by-id is mandatory: /dev/sdX is not stable across reboots.
  local d
  for d in "${DISKS[@]}"; do
    [[ "$d" == /dev/disk/by-id/* ]] || die "DISKS must use /dev/disk/by-id/, got: $d"
  done

  local n=${#DISKS[@]}
  case "$TOPOLOGY" in
    single)  (( n == 1 )) || die "TOPOLOGY=single needs exactly 1 disk, got $n" ;;
    mirror)  (( n >= 2 )) || die "TOPOLOGY=mirror needs >= 2 disks, got $n" ;;
    raidz1)  (( n >= 3 )) || die "TOPOLOGY=raidz1 needs >= 3 disks, got $n" ;;
    raidz2)  (( n >= 4 )) || die "TOPOLOGY=raidz2 needs >= 4 disks, got $n" ;;
    raidz3)  (( n >= 5 )) || die "TOPOLOGY=raidz3 needs >= 5 disks, got $n" ;;
  esac

  if [[ "$CLASS" == "mini" ]]; then
    (( n == 1 )) || die "CLASS=mini must have exactly 1 disk, got $n"
  else
    [[ "$TOPOLOGY" != "single" ]] || die "CLASS=server with TOPOLOGY=single is not a server profile"
  fi

  if [[ "$BOOT_MODE" != "uefi" ]]; then
    warn "BOOT_MODE=$BOOT_MODE: GRUB will not boot from a 4Kn disk under legacy BIOS — check the hardware"
  fi

  if [[ "$ADDRESS" == "static" ]]; then
    [[ -n "$IPV4" && -n "$CIDR" && -n "$GATEWAY" ]] || die "static addressing needs IPV4, CIDR, GATEWAY"
  fi

  # Optional login user. The password is a pre-computed hash (openssl passwd -6) —
  # never plaintext: the profile lives on the carrier USB.
  if [[ -z "$USERNAME" ]]; then
    [[ -z "$USER_PASSWORD_HASH" && -z "$USER_AUTHORIZED_KEYS" ]] \
      || die "USER_PASSWORD_HASH/USER_AUTHORIZED_KEYS need USERNAME"
  else
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$USERNAME" != "root" ]] \
      || die "bad USERNAME: $USERNAME"
    [[ "$USER_SHELL" == /* ]] || die "USER_SHELL must be an absolute path"
    if [[ -z "$USER_PASSWORD_HASH" && -z "$USER_AUTHORIZED_KEYS" ]]; then
      die "USERNAME=$USERNAME has neither password hash nor SSH key — the account could never log in"
    fi
    [[ -z "$USER_PASSWORD_HASH" || "$USER_PASSWORD_HASH" =~ ^\$[0-9a-z]+\$.+ ]] \
      || die "USER_PASSWORD_HASH must be a crypt hash like \$6\$salt\$hash (openssl passwd -6)"
    if [[ -n "$USER_AUTHORIZED_KEYS" ]]; then
      [[ -r "$USER_AUTHORIZED_KEYS" ]] || die "USER_AUTHORIZED_KEYS not readable: $USER_AUTHORIZED_KEYS"
    fi
  fi

  # Serial console. Debian servers are headless, so the LUKS prompt and the boot log have to
  # be reachable somewhere other than a monitor; GRUB needs the unit and speed separately.
  if [[ -n "$SERIAL_CONSOLE" ]]; then
    [[ "$SERIAL_CONSOLE" =~ ^ttyS([0-3])(,([0-9]+))?$ ]] \
      || die "SERIAL_CONSOLE must look like 'ttyS0,115200' (got: $SERIAL_CONSOLE)"
    SERIAL_UNIT="${BASH_REMATCH[1]}"
    SERIAL_SPEED="${BASH_REMATCH[3]:-115200}"
    SERIAL_CONSOLE="ttyS${SERIAL_UNIT},${SERIAL_SPEED}"
    ok "serial console enabled on $SERIAL_CONSOLE (GRUB + kernel + getty)"
  fi

  ok "profile is well formed ($n disk(s), topology=$TOPOLOGY, boot=$BOOT_MODE)"
}

preflight() {
  stage "Preflight"

  local t
  for t in sgdisk zpool zfs mdadm cryptsetup grub-install update-grub zstd; do
    command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
  done
  ok "required tools present"

  [[ "$(zfs --version 2>/dev/null | head -1)" == *2.4.* ]] \
    || warn "live environment OpenZFS is not 2.4.x — it must not be NEWER than the target's"
  ok "live environment OpenZFS: $(zfs --version 2>/dev/null | head -1)"

  local d
  for d in "${DISKS[@]}"; do
    [[ -b "$d" ]] || die "not a block device: $d"
  done
  ok "all target disks resolve"

  if [[ "$CRYPT" == "yes" ]] && (( ! ASSUME_YES )); then
    log "LUKS2 passphrase will be prompted for each disk container"
  fi

  [[ -r "$GOLDEN_STREAM" ]] || die "golden stream not found: $GOLDEN_STREAM"
  ok "golden stream present: $GOLDEN_STREAM ($(du -h "$GOLDEN_STREAM" | cut -f1))"

  [[ -r "$BOOT_PAYLOAD" ]] || die "boot payload not found: $BOOT_PAYLOAD"
  ok "boot payload present: $BOOT_PAYLOAD"
}

show_plan() {
  stage "Plan for '$PROFILE_NAME' (${CLASS}, ${HOSTNAME})"
  cat >&2 <<EOF
  pool ............ $POOL ($TOPOLOGY)
  disks ........... ${DISKS[*]}
  boot disks ...... ${BOOT_DISKS[*]}
  firmware ........ $BOOT_MODE
  encryption ...... LUKS2 under ZFS: $CRYPT
  swap ............ $SWAP ${SWAP:+($SWAP_SIZE)}   zswap=$ZSWAP  zram=$ZRAM
  address ......... $ADDRESS ${IPV4:+$IPV4/$CIDR}
  serial console .. ${SERIAL_CONSOLE:-none (VGA only)}
  login user ...... ${USERNAME:-none (root only)}

  Layout per disk:
    p1  $ESP_SIZE   EF00  ESP (FAT32)
EOF
  [[ "$BOOT_MODE" != "uefi" ]] && printf '    p2  %-6s EF02  BIOS Boot Partition\n' "$BIOS_SIZE" >&2
  if [[ "$CLASS" == "server" ]]; then
    printf '    p3  %-6s FD00  mdadm RAID1 member -> ext4 /boot\n' "$BOOT_SIZE" >&2
  else
    printf '    p3  %-6s 8300  ext4 /boot\n' "$BOOT_SIZE" >&2
  fi
  [[ "$SWAP" == "ephemeral" ]] && printf '    p4  %-6s 8200  encrypted swap (ephemeral key)\n' "$SWAP_SIZE" >&2
  printf '    pN  rest     BF00  LUKS2 -> %s vdev member\n' "$POOL" >&2

  if (( ! APPLY )); then
    printf '\n  DRY RUN — nothing will be written. Re-run with --apply.\n' >&2
  fi
}

confirm_disks() {
  (( ASSUME_YES )) && return 0
  (( APPLY )) || return 0
  printf '\nThis WILL DESTROY all data on:\n' >&2
  printf '  %s\n' "${DISKS[@]}" >&2
  read -r -p "Type 'yes' to continue: " reply
  [[ "$reply" == "yes" ]] || die "aborted by operator"
}

# --------------------------------------------------------------------------- partition layout

# Builds the sgdisk argument list for one disk into the global array SGDISK_ARGS, and records
# the partition *indices* in PART_*_IDX. Partition device paths are resolved separately, and
# only AFTER partitioning, by resolve_partitions.
build_partition_plan() {
  SGDISK_ARGS=()
  PART_ESP_IDX=""; PART_BIOS_IDX=""; PART_BOOT_IDX=""; PART_SWAP_IDX=""; PART_ZFS_IDX=""
  local idx=0

  idx=$((idx + 1)); PART_ESP_IDX="$idx"
  SGDISK_ARGS+=(-n "${idx}:0:+${ESP_SIZE}" -t "${idx}:EF00" -c "${idx}:esp")

  if [[ "$BOOT_MODE" != "uefi" ]]; then
    idx=$((idx + 1)); PART_BIOS_IDX="$idx"
    SGDISK_ARGS+=(-n "${idx}:0:+${BIOS_SIZE}" -t "${idx}:EF02" -c "${idx}:bios")
  fi

  idx=$((idx + 1)); PART_BOOT_IDX="$idx"
  if [[ "$CLASS" == "server" ]]; then
    SGDISK_ARGS+=(-n "${idx}:0:+${BOOT_SIZE}" -t "${idx}:FD00" -c "${idx}:boot")
  else
    SGDISK_ARGS+=(-n "${idx}:0:+${BOOT_SIZE}" -t "${idx}:8300" -c "${idx}:boot")
  fi

  if [[ "$SWAP" == "ephemeral" ]]; then
    idx=$((idx + 1)); PART_SWAP_IDX="$idx"
    SGDISK_ARGS+=(-n "${idx}:0:+${SWAP_SIZE}" -t "${idx}:8200" -c "${idx}:swap")
  fi

  idx=$((idx + 1)); PART_ZFS_IDX="$idx"
  SGDISK_ARGS+=(-n "${idx}:0:0" -t "${idx}:BF00" -c "${idx}:zfs")
}

# Resolve one partition's device path.
#
# udev publishes partition symlinks as <by-id-path>-part<N>, e.g.
#   /dev/disk/by-id/ata-FOO  ->  /dev/disk/by-id/ata-FOO-part1
# so appending the index to the disk path is wrong. Fall back to resolving the symlink to its
# kernel name and applying the usual kernel convention (/dev/sda1, /dev/nvme0n1p1, /dev/loop0p1).
part_dev() {
  local disk="$1" idx="$2" real
  if [[ -e "${disk}-part${idx}" ]]; then
    printf '%s' "${disk}-part${idx}"
    return
  fi
  real="$(readlink -f "$disk")"
  if [[ "$real" =~ [0-9]$ ]]; then
    printf '%sp%s' "$real" "$idx"
  else
    printf '%s%s' "$real" "$idx"
  fi
}

# Populate PART_ESP / PART_BIOS / PART_BOOT / PART_SWAP / PART_ZFS for one disk.
resolve_partitions() {
  local disk="$1"
  build_partition_plan "$disk"
  PART_ESP="$(part_dev "$disk" "$PART_ESP_IDX")"
  PART_BOOT="$(part_dev "$disk" "$PART_BOOT_IDX")"
  PART_ZFS="$(part_dev "$disk" "$PART_ZFS_IDX")"
  # PART_BIOS is deliberately not resolved: grub-pc installs to the whole disk, never to the
  # BIOS Boot Partition device.
  PART_SWAP=""
  [[ -n "$PART_SWAP_IDX" ]] && PART_SWAP="$(part_dev "$disk" "$PART_SWAP_IDX")"
  return 0
}

stage_partition() {
  stage "Partitioning"
  local disk
  for disk in "${DISKS[@]}"; do
    build_partition_plan "$disk"
    log "$disk: esp=p$PART_ESP_IDX${PART_BIOS_IDX:+ bios=p$PART_BIOS_IDX} boot=p$PART_BOOT_IDX${PART_SWAP_IDX:+ swap=p$PART_SWAP_IDX} zfs=p$PART_ZFS_IDX"
    run sgdisk --zap-all "$disk"
    run sgdisk "${SGDISK_ARGS[@]}" "$disk"
    # partprobe comes from parted, which a minimal live image may not carry.
    # partx is util-linux and is always present, so fall back to it.
    if command -v partprobe >/dev/null 2>&1; then
      run partprobe "$disk"
    else
      run partx -u "$disk"
    fi
    run udevadm settle
  done
  ok "partitioned ${#DISKS[@]} disk(s)"
}

# --------------------------------------------------------------------------- /boot

stage_boot() {
  stage "/boot (ext4"
  if [[ "$CLASS" == "server" ]]; then
    printf ' on mdadm RAID1)\n' >&2
    local parts=() d
    for d in "${DISKS[@]}"; do
      resolve_partitions "$d"
      parts+=("$PART_BOOT")
    done
    # Defensive: a previous attempt on this machine may have left an array assembled.
    if [[ -e /dev/md0 ]]; then
      warn "/dev/md0 already exists — stopping it before creating the new array"
      umount /dev/md0 2>/dev/null || true
      run mdadm --stop /dev/md0 || die "could not stop the existing /dev/md0 — is /boot still mounted?"
      run udevadm settle
    fi
    # --bitmap=none suppresses mdadm's interactive "enable write-intent bitmap?" prompt,
    # which would otherwise block an unattended run.
    run mdadm --create /dev/md0 --level=1 --raid-devices="${#parts[@]}" \
      --metadata=1.2 --bitmap=none --run "${parts[@]}"
    run udevadm settle
    # GRUB parses md metadata itself; this keeps the running live env in sync.
    run mkfs.ext4 -F -L boot /dev/md0
    BOOT_DEV="/dev/md0"
  else
    printf ')\n' >&2
    resolve_partitions "${DISKS[0]}"
    run mkfs.ext4 -F -L boot "$PART_BOOT"
    BOOT_DEV="$PART_BOOT"
  fi
  ok "/boot ready on $BOOT_DEV"
}

# --------------------------------------------------------------------------- encryption

stage_luks() {
  stage "LUKS2 containers"
  if [[ "$CRYPT" != "yes" ]]; then
    warn "CRYPT=no — pool will be created on raw partitions"
    LUKS_MEMBERS=("${DISKS[@]}")
    return 0
  fi
  LUKS_MEMBERS=()
  CRYPTTAB_LINES=()
  local i=0 d part name uuid
  local keyargs=()
  # LUKS_KEYFILE allows non-interactive provisioning (automation, and the VM smoke test).
  # Without it, cryptsetup prompts once per container.
  if [[ -n "$LUKS_KEYFILE" ]]; then
    [[ -r "$LUKS_KEYFILE" ]] || die "LUKS_KEYFILE not readable: $LUKS_KEYFILE"
    keyargs=(--key-file "$LUKS_KEYFILE")
    warn "using LUKS_KEYFILE ($LUKS_KEYFILE) — do not leave it on the carrier medium"
  fi
  for d in "${DISKS[@]}"; do
    resolve_partitions "$d"
    part="$PART_ZFS"
    name="zfs${i}"
    # SSDs (ROTA=0: SATA SSD, NVMe) skip dm-crypt's workqueues — lower latency, less
    # CPU. `discard` is already on every line; HDDs keep the workqueues (throughput).
    opts="luks,discard,initramfs,nofail"
    if [[ "$(lsblk -dnro ROTA "$part" 2>/dev/null)" == "0" ]]; then
      opts="$opts,no-read-workqueue,no-write-workqueue"
      log "$part is non-rotational — dm-crypt workqueue bypass enabled for $name"
    fi
    if (( APPLY )); then
      cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha256 --pbkdf argon2id \
        --label "$name" "${keyargs[@]}" "$part"
      cryptsetup open "${keyargs[@]}" "$part" "$name"
      # Reference the container by its LUKS UUID, not its device path. Device names are not
      # stable (sda/sdb swap across reboots); the LUKS UUID is. crypttab(5) supports
      # "UUID=<uuid>" in the source-device field.
      uuid="$(cryptsetup luksUUID "$part")"
      # nofail: a missing disk (single-disk boot of a mirror, DESIGN.md §14) must not
      # stall the boot for 90 s per absent container — the pool imports degraded.
      CRYPTTAB_LINES+=("$name UUID=$uuid none $opts")
    else
      printf '  would run: cryptsetup luksFormat --type luks2 ... %s\n' "$part" >&2
      printf '  would run: cryptsetup open %s %s\n' "$part" "$name" >&2
      printf '  crypttab options for %s would be: %s\n' "$name" "$opts" >&2
      CRYPTTAB_LINES+=("$name UUID=<luks-uuid> none $opts")
    fi
    LUKS_MEMBERS+=("/dev/mapper/$name")
    i=$((i + 1))
  done
  ok "${#LUKS_MEMBERS[@]} LUKS2 container(s)"
}

# --------------------------------------------------------------------------- pool

stage_pool() {
  stage "Creating pool '$POOL'"

  # TODO-VALIDATE: generate a per-machine hostid before pool creation. zgenhostid writes
  # /etc/hostid; whether it also updates the *running* kernel hostid that ZFS reads via
  # gethostid() is unclear. If the pool-label hostid and the target's /etc/hostid disagree,
  # the symptom is "pool may be in use from other system" and the fix is a one-off
  # `zpool import -f`. Confirm on a scratch VM.
  run zgenhostid -f

  local vdev_args=()
  case "$TOPOLOGY" in
    single) vdev_args=("${LUKS_MEMBERS[0]}") ;;
    mirror) vdev_args=(mirror "${LUKS_MEMBERS[@]}") ;;
    raidz1) vdev_args=(raidz1 "${LUKS_MEMBERS[@]}") ;;
    raidz2) vdev_args=(raidz2 "${LUKS_MEMBERS[@]}") ;;
    raidz3) vdev_args=(raidz3 "${LUKS_MEMBERS[@]}") ;;
  esac

  # No compatibility pin: the live image is built from the same trixie-backports source as
  # the target, so the live OpenZFS is never newer than the target's. See DESIGN.md §6.
  run zpool create -f \
    -o ashift=12 \
    -O compression=zstd \
    -O acltype=posixacl \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=none \
    "$POOL" "${vdev_args[@]}"

  # bootfs is set in stage_recv: the dataset it names does not exist until then.
  ok "pool created (ashift=12, no compatibility ceiling)"
}

# --------------------------------------------------------------------------- receive

stage_recv() {
  stage "Receiving golden root"
  run mkdir -p "$MNT"
  if (( APPLY )); then
    if [[ "$GOLDEN_STREAM" == *.zst ]]; then
      zstd -dc "$GOLDEN_STREAM" | zfs recv -F -u -o canmount=off -o mountpoint=none "$POOL"
    else
      zfs recv -F -u -o canmount=off -o mountpoint=none "$POOL" < "$GOLDEN_STREAM"
    fi
  else
    if [[ "$GOLDEN_STREAM" == *.zst ]]; then
      printf '  would run: zstd -dc %s | zfs recv -F -u %s\n' "$GOLDEN_STREAM" "$POOL" >&2
    else
      printf '  would run: zfs recv -F -u %s < %s\n' "$POOL" "$GOLDEN_STREAM" >&2
    fi
  fi
  # Restore the real layout explicitly. No altroot is used anywhere in this script: altroot is
  # a PERSISTENT pool property, and clearing it later proved unreliable (the pool ends up busy
  # and refuses to export). Creating the pool with mountpoint=none and setting the mountpoints
  # by hand leaves nothing to clean up.
  run zfs set canmount=noauto mountpoint="$MNT" "$POOL/ROOT/debian"
  run zfs mount "$POOL/ROOT/debian"
  # bootfs is how the initramfs knows which dataset to mount as root.
  run zpool set bootfs="$POOL/ROOT/debian" "$POOL"
  ok "golden root received and mounted at $MNT"
}

# --------------------------------------------------------------------------- /boot payload

# TODO-VALIDATE: /boot lives OUTSIDE the pool, so it is not in the zfs send stream.
# The kernel and initramfs must be restored separately, then regenerated per machine
# (the initramfs embeds LUKS config and dropbear host keys).
stage_boot_payload() {
  stage "Populating ext4 /boot"
  run mount "$BOOT_DEV" "$MNT/boot"
  if (( APPLY )); then
    tar --zstd -xf "$BOOT_PAYLOAD" -C "$MNT/boot"
  else
    printf '  would run: tar --zstd -xf %s -C %s/boot\n' "$BOOT_PAYLOAD" "$MNT" >&2
  fi
  ok "/boot populated"
}

stage_chroot_config() {
  stage "Target configuration (chroot)"

  if (( APPLY )); then
    for fs in dev dev/pts proc sys; do mount --rbind "/$fs" "$MNT/$fs"; done
    mount --make-rslave "$MNT/dev" || true
  fi

  # no-hibernation, unconditionally (see DESIGN.md §8.1)
  run mkdir -p "$MNT/etc/systemd/sleep.conf.d"
  if (( APPLY )); then
    cat > "$MNT/etc/systemd/sleep.conf.d/10-no-hibernate.conf" <<'EOF'
[Sleep]
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF
  else
    printf '  would write: %s/etc/systemd/sleep.conf.d/10-no-hibernate.conf\n' "$MNT" >&2
  fi

  run chroot "$MNT" bash -euo pipefail -c "
    systemctl mask hibernate.target hybrid-sleep.target suspend-then-hibernate.target \
      systemd-hibernate.service systemd-hybrid-sleep.service systemd-suspend-then-hibernate.service
    systemctl mask sleep.target suspend.target || true
    echo '$HOSTNAME' > /etc/hostname
  "

  # Keep the target's hostid equal to the one the pool was created with, so the machine and
  # the pool label agree. seal-identity.sh only generates one if this is somehow missing.
  if (( APPLY )); then
    install -m 0644 /etc/hostid "$MNT/etc/hostid"
  else
    printf '  would install: /etc/hostid -> %s/etc/hostid\n' "$MNT" >&2
  fi

  # Addressing (systemd-networkd backend). Always write 10-wired.network: networkd with
  # no .network files does nothing, so the DHCP path must write DHCP=yes explicitly —
  # relying on the "golden image default" left DHCP machines with no address.
  if (( APPLY )); then
    mkdir -p "$MNT/etc/systemd/network"
    if [[ "$ADDRESS" == "static" ]]; then
      {
        printf '[Match]\nName=en*\n\n[Network]\n'
        printf 'Address=%s/%s\n' "$IPV4" "$CIDR"
        printf 'Gateway=%s\n' "$GATEWAY"
        [[ -n "$DNS" ]] && printf 'DNS=%s\n' "$DNS"
      } > "$MNT/etc/systemd/network/10-wired.network"
    else
      {
        printf '[Match]\nName=en*\n\n[Network]\n'
        printf 'DHCP=yes\n'
      } > "$MNT/etc/systemd/network/10-wired.network"
    fi
    chroot "$MNT" systemctl enable systemd-networkd
  else
    if [[ "$ADDRESS" == "static" ]]; then
      printf '  would write: %s/etc/systemd/network/10-wired.network (static %s/%s)\n' \
        "$MNT" "$IPV4" "$CIDR" >&2
    else
      printf '  would write: %s/etc/systemd/network/10-wired.network (DHCP)\n' "$MNT" >&2
    fi
  fi

  # fstab: /boot and the ESP live outside the pool. ZFS datasets are mounted by zfs-mount.
  # nofail on both: booting with a disk missing (DESIGN.md §14 single-disk boot) must
  # not drop to emergency mode over an absent /boot member or a foreign ESP UUID.
  if (( APPLY )); then
    local boot_uuid
    boot_uuid="$(blkid -s UUID -o value "$BOOT_DEV")"
    {
      printf '# generated by zfs-stamp.sh for profile %s\n' "$PROFILE_NAME"
      printf 'UUID=%s\t/boot\text4\tdefaults,noatime,nofail\t0\t2\n' "$boot_uuid"
      if [[ "$BOOT_MODE" != "bios" ]]; then
        printf 'UUID=%s\t/boot/efi\tvfat\tumask=0077,shortname=winnt,nofail\t0\t2\n' "$ESP_UUID"
      fi
    } > "$MNT/etc/fstab"
  else
    printf '  would write: %s/etc/fstab (/boot + ESP)\n' "$MNT" >&2
  fi

  # Mini PCs: encrypted swap with an ephemeral per-boot key. crypttab plain mode keyed from
  # /dev/urandom IS the ephemeral-key mechanism: no LUKS header, no persistent key, nothing
  # to unlock, and no resumable image (which is the point). zswap caches in front of it.
  # noearly: the initramfs has no business setting up this swap (nothing resumes from it —
  # hibernation is disabled four ways). systemd-cryptsetup creates it at real boot instead.
  # Without noearly, every boot prints "swap: couldn't determine device type" and
  # "Resume target swap uses a key file" from the initramfs cryptsetup scripts.
  if [[ "$SWAP" == "ephemeral" ]]; then
    resolve_partitions "${DISKS[0]}"
    local swap_part="$PART_SWAP"
    # Same SSD workqueue bypass as the pool containers (plain dm-crypt honors it too).
    local swap_opts="swap,cipher=aes-xts-plain64,size=512,noearly"
    if [[ "$(lsblk -dnro ROTA "$swap_part" 2>/dev/null)" == "0" ]]; then
      swap_opts="$swap_opts,no-read-workqueue,no-write-workqueue"
    fi
    if (( APPLY )); then
      printf 'swap\t%s\t/dev/urandom\t%s\n' "$swap_part" "$swap_opts" \
        >> "$MNT/etc/crypttab"
      printf '/dev/mapper/swap\tnone\tswap\tsw\t0\t0\n' >> "$MNT/etc/fstab"
    else
      printf '  would add: crypttab ephemeral swap on %s + fstab entry\n' "$swap_part" >&2
    fi
  fi

  # crypttab entries for the pool's LUKS containers. Without these the initramfs does not
  # know to unlock them, so the pool is never imported and the machine does not boot.
  if (( ${#CRYPTTAB_LINES[@]} > 0 )); then
    if (( APPLY )); then
      {
        printf '# pool containers — unlocked from the initramfs via dropbear\n'
        printf '%s\n' "${CRYPTTAB_LINES[@]}"
      } >> "$MNT/etc/crypttab"
    else
      printf '  would add: %d crypttab entr(ies) for the pool containers\n' \
        "${#CRYPTTAB_LINES[@]}" >&2
    fi
  fi

  # CRITICAL. Debian's cryptsetup-initramfs only pulls itself into the initramfs when it can
  # identify an encrypted ROOT device. With ZFS-on-LUKS the root is a *dataset*, so that
  # detection never fires: the initramfs ships without cryptsetup or the cryptroot script, and
  # the machine cannot unlock its containers and therefore does not boot.
  # Verified in a VM: without this, `lsinitramfs` has zero cryptsetup and zero dropbear
  # entries; with CRYPTSETUP=y it has the cryptroot script and both sets of binaries.
  if [[ "$CRYPT" == "yes" ]]; then
    if (( APPLY )); then
      mkdir -p "$MNT/etc/cryptsetup-initramfs"
      if grep -qE '^#?CRYPTSETUP=' "$MNT/etc/cryptsetup-initramfs/conf-hook" 2>/dev/null; then
        sed -i 's/^#\?CRYPTSETUP=.*/CRYPTSETUP=y/' "$MNT/etc/cryptsetup-initramfs/conf-hook"
      else
        printf 'CRYPTSETUP=y\n' >> "$MNT/etc/cryptsetup-initramfs/conf-hook"
      fi
      log "forced CRYPTSETUP=y in conf-hook ($(grep -c '^CRYPTSETUP=y' "$MNT/etc/cryptsetup-initramfs/conf-hook") match)"
    else
      printf '  would set: CRYPTSETUP=y in %s/etc/cryptsetup-initramfs/conf-hook\n' "$MNT" >&2
    fi
  fi

  # Per-machine kernel command line. The golden image ships /etc/default/grub.d/99-zfs-root.cfg
  # with the class-independent bits (nohibernate, cryptodisk). grub-mkconfig sources
  # /etc/default/grub.d/*.cfg AFTER /etc/default/grub, so appending to the variables here works
  # and the golden defaults are preserved.
  #
  # stage_grub runs update-grub, which is what turns this file into /boot/grub/grub.cfg.
  # Without update-grub grub-install leaves GRUB with modules and no menu, and the machine
  # boots straight into the `grub>` prompt — that is not a hypothetical, it is what the first
  # stamped image did.
  local extras=() extra_line="" cmdline_extra=""
  if [[ "$SWAP" == "ephemeral" && -r "$MNT/etc/default/zfs-stamp-cmdline" ]]; then
    # Written by the golden image; zswap only means anything on a machine with a swap device,
    # which is the mini class. Reading it here is what actually puts it on the command line.
    extra_line="$(grep -vE '^[[:space:]]*(#|$)' "$MNT/etc/default/zfs-stamp-cmdline" | tr '\n' ' ')"
    [[ -n "${extra_line// /}" ]] && extras+=("$extra_line")
  fi
  if [[ -n "$SERIAL_CONSOLE" ]]; then
    # tty0 first: kernel messages still reach a monitor, while /dev/console (and therefore the
    # initramfs LUKS prompt) is the LAST console= on the line — the serial port.
    extras+=("console=tty0 console=$SERIAL_CONSOLE")
  fi
  if ((${#extras[@]})); then cmdline_extra=" ${extras[*]}"; fi

  if (( APPLY )); then
    mkdir -p "$MNT/etc/default/grub.d"
    {
      printf '# Written by zfs-stamp.sh for profile %s — do not edit by hand.\n' "$PROFILE_NAME"
      printf '# Regenerate /boot/grub/grub.cfg with: update-grub\n'
      printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT%s"\n' "$cmdline_extra"
      if [[ -n "$SERIAL_CONSOLE" ]]; then
        printf 'GRUB_TERMINAL="console serial"\n'
        printf 'GRUB_SERIAL_COMMAND="serial --unit=%s --speed=%s"\n' "$SERIAL_UNIT" "$SERIAL_SPEED"
      fi
    } > "$MNT/etc/default/grub.d/99-zfs-stamp.cfg"
    log "kernel cmdline extras:${cmdline_extra:- (none)}"
  else
    printf '  would write: %s/etc/default/grub.d/99-zfs-stamp.cfg%s\n' "$MNT" "$cmdline_extra" >&2
  fi

  if [[ -n "$SERIAL_CONSOLE" ]]; then
    run chroot "$MNT" systemctl enable "serial-getty@ttyS$SERIAL_UNIT.service"
  fi

  # /boot lives on an mdadm array, so the initramfs must be able to assemble it. Anchor the
  # array by UUID rather than by device name.
  if [[ "$CLASS" == "server" ]]; then
    if (( APPLY )); then
      mkdir -p "$MNT/etc/mdadm"
      {
        printf 'DEVICE partitions\n'
        printf 'HOMEHOST <system>\n'
        mdadm --detail --scan
      } > "$MNT/etc/mdadm/mdadm.conf"
    else
      printf '  would write: %s/etc/mdadm/mdadm.conf (array by UUID)\n' "$MNT" >&2
    fi
  fi

  # Memory: zram on servers, zswap on mini PCs (DESIGN.md §8.2). An /etc config file OVERRIDES
  # the vendor default wholesale, so it must be written either way:
  #
  #   * systemd-zram-generator ships /usr/lib/systemd/zram-generator.conf containing a bare
  #     `[zram0]` section. With no /etc file that default applies and zram0 IS created — so a
  #     mini PC that only ever writes a config when ZRAM=yes silently gets zram swap on top of
  #     its ephemeral disk swap, which is not the design. Verified: with no /etc file the
  #     generator emits dev-zram0.swap; with a comment-only /etc file it emits nothing.
  #   * zram-size takes an EXPRESSION in MiB as a function of MemTotal, NOT a percentage.
  #     `zram-size = 50%` makes the generator exit with "Error: zram-size zram0" and create no
  #     device at all — which on a server (SWAP=none) means ZERO swap, not 50% of RAM.
  if (( APPLY )); then
    mkdir -p "$MNT/etc/systemd"
    if [[ "$ZRAM" == "yes" ]]; then
      printf '[zram0]\nzram-size = %s\ncompression-algorithm = zstd\n' "$ZRAM_SIZE" \
        > "$MNT/etc/systemd/zram-generator.conf"
      log "zram0 configured: zram-size = $ZRAM_SIZE"
    else
      # No [zram0] section = no zram device. This is upstream's documented way to disable it.
      cat > "$MNT/etc/systemd/zram-generator.conf" <<'EOF'
# zram explicitly disabled for this machine (its class uses disk swap/zswap instead).
# Do not add a [zram0] section: its presence is what creates the device. This file also
# overrides the [zram0] section shipped in /usr/lib/systemd/zram-generator.conf.
EOF
      log "zram disabled (empty config overrides the vendor default)"
    fi
  else
    printf '  would write: %s/etc/systemd/zram-generator.conf (ZRAM=%s, size=%s)\n' \
      "$MNT" "$ZRAM" "$ZRAM_SIZE" >&2
  fi

  ok "target configuration files written"
}

# dropbear-initramfs needs an authorized_keys file or nobody can log in to the initramfs,
# which means the LUKS containers can never be unlocked. The "Invalid authorized_keys file"
# warning emitted during the golden image build is exactly this gap.
stage_dropbear() {
  stage "dropbear-initramfs remote unlock"
  if [[ -z "$DROPBEAR_AUTHORIZED_KEYS" ]]; then
    warn "DROPBEAR_AUTHORIZED_KEYS is not set — remote unlock will NOT work on this machine"
    warn "set it in the profile to a public key file on the carrier medium"
    return 0
  fi
  [[ -r "$DROPBEAR_AUTHORIZED_KEYS" ]] \
    || die "DROPBEAR_AUTHORIZED_KEYS not readable: $DROPBEAR_AUTHORIZED_KEYS"
  if (( APPLY )); then
    mkdir -p "$MNT/etc/dropbear/initramfs"
    install -m 0600 "$DROPBEAR_AUTHORIZED_KEYS" "$MNT/etc/dropbear/initramfs/authorized_keys"
  else
    printf '  would install: %s -> %s/etc/dropbear/initramfs/authorized_keys\n' \
      "$DROPBEAR_AUTHORIZED_KEYS" "$MNT" >&2
  fi

  # The golden image ships WITHOUT dropbear initramfs host keys (identity hygiene, so the
  # fleet does not share one key). Generate this machine's keys now: without them dropbear
  # cannot start in the initramfs, and the FIRST boot could never be unlocked remotely.
  if (( APPLY )); then
    mkdir -p "$MNT/etc/dropbear/initramfs"
    chroot "$MNT" sh -c '
      cd /etc/dropbear/initramfs
      [ -s dropbear_ed25519_host_key ] || dropbearkey -t ed25519 -f dropbear_ed25519_host_key >/dev/null
      [ -s dropbear_rsa_host_key ]     || dropbearkey -t rsa -s 3072 -f dropbear_rsa_host_key >/dev/null
    ' || die "could not generate dropbear initramfs host keys — remote unlock would fail"
  else
    printf '  would generate per-machine dropbear initramfs host keys\n' >&2
  fi

  # The initramfs brings the NIC up with the ip= kernel parameter. dhcp is fine on a network
  # you control, but a static address means you always know where to SSH after a power event.
  if [[ "$ADDRESS" == "static" ]]; then
    log "dropbear reachable at ${IPV4} (static ip= parameter)"
  else
    log "dropbear on DHCP — use a reservation, or you will not know where to connect"
  fi
  ok "dropbear remote unlock configured"
}

# Optional login user with sudo. Empty USERNAME = root-only, as before.
# Sudo membership needs the sudo group, i.e. the sudo package in the golden
# image (build/golden-packages.list) — usermod fails loudly without it.
stage_user() {
  [[ -n "$USERNAME" ]] || { log "no login user requested (USERNAME empty)"; return 0; }
  stage "Login user '$USERNAME' (sudo)"
  if (( APPLY )); then
    if chroot "$MNT" id "$USERNAME" >/dev/null 2>&1; then
      die "user $USERNAME already exists in the target — refusing to change an existing account"
    fi
    # rpool/home is a separate dataset, received unmounted (mountpoint=none). Mount it
    # at $MNT/home NOW, so useradd -m lands on the dataset that will be /home at boot.
    # Otherwise the home dir is written to the root dataset and hidden under the home
    # mount on first boot — login works, but there is no home directory. Teardown is
    # already covered: unmount_target() releases $POOL/home by name, and stage_finish
    # restores mountpoint=/home.
    run zfs set canmount=noauto mountpoint="$MNT/home" "$POOL/home"
    run zfs mount "$POOL/home"
    chroot "$MNT" useradd -m -s "$USER_SHELL" "$USERNAME" \
      || die "useradd failed for $USERNAME"
    chroot "$MNT" usermod -aG sudo "$USERNAME" \
      || die "usermod -aG sudo failed — is sudo installed in the golden image?"
    if [[ -n "$USER_PASSWORD_HASH" ]]; then
      printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD_HASH" | chroot "$MNT" chpasswd -e \
        || die "could not set password for $USERNAME"
    else
      log "no password hash — $USERNAME is SSH-key-only (password locked)"
    fi
    if [[ -n "$USER_AUTHORIZED_KEYS" ]]; then
      # install(1) -o/-g would resolve the name on the HOST, where the user does
      # not exist — install as root, then fix ownership inside the target so
      # sshd StrictModes accepts ~/.ssh.
      chroot "$MNT" mkdir -p "/home/$USERNAME/.ssh"
      install -m 0600 "$USER_AUTHORIZED_KEYS" \
        "$MNT/home/$USERNAME/.ssh/authorized_keys" \
        || die "could not install authorized_keys for $USERNAME"
      chroot "$MNT" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh" \
        || die "could not fix ownership of /home/$USERNAME/.ssh"
    fi
    ok "user $USERNAME created with sudo"
  else
    printf '  would create: user %s (shell %s) in sudo group' "$USERNAME" "$USER_SHELL" >&2
    [[ -n "$USER_PASSWORD_HASH" ]] && printf ', password from hash' >&2
    [[ -n "$USER_AUTHORIZED_KEYS" ]] && printf ', authorized_keys from %s' "$USER_AUTHORIZED_KEYS" >&2
    printf '\n' >&2
  fi
}

# The initramfs must be regenerated LAST: it has to contain the target's crypttab, fstab
# and dropbear authorized_keys, all of which are written in the stages above.
stage_initramfs() {
  stage "Regenerating initramfs"
  run chroot "$MNT" update-initramfs -u -k all
  if (( APPLY )); then
    for fs in sys proc dev/pts dev; do umount -R "$MNT/$fs" 2>/dev/null || true; done
  fi
  ok "initramfs regenerated with the target's crypttab and dropbear keys"
}

# Last line of defence. The first stamped image reported `[ ok ] installed` while GRUB had no
# menu at all and the machine could never have booted. Everything checked here is cheap, and
# every check corresponds to a way the target can fail to start. A machine that cannot boot
# must fail loudly here rather than silently in front of an operator with no console.
stage_verify() {
  (( APPLY )) || return 0
  stage "Verifying the target can actually boot"
  local bad=0

  # 1. GRUB has a menu that names the pool's boot dataset.
  if [[ ! -s "$MNT/boot/grub/grub.cfg" ]]; then
    warn "/boot/grub/grub.cfg is missing — GRUB would drop to its command prompt"
    bad=1
  elif ! grep -q "root=ZFS=$POOL/ROOT/debian" "$MNT/boot/grub/grub.cfg"; then
    warn "grub.cfg has no root=ZFS=$POOL/ROOT/debian line — the kernel would not find its root"
    bad=1
  else
    ok "grub.cfg present, names root=ZFS=$POOL/ROOT/debian"
  fi

  # 2. Hibernation must be off on the kernel line too (DESIGN.md §8.1); sleep.conf.d alone does
  #    not stop a resumable image being used.
  if grep -qs 'nohibernate' "$MNT/boot/grub/grub.cfg"; then
    ok "kernel line carries nohibernate"
  else
    warn "nohibernate missing from grub.cfg — hibernation is not fully disabled"
    bad=1
  fi

  # 3. Serial console, if the profile asked for one, must reach all three layers.
  if [[ -n "$SERIAL_CONSOLE" ]]; then
    if grep -qs "console=$SERIAL_CONSOLE" "$MNT/boot/grub/grub.cfg"; then
      ok "kernel line carries console=$SERIAL_CONSOLE"
    else
      warn "SERIAL_CONSOLE=$SERIAL_CONSOLE is set but not on the kernel line"
      bad=1
    fi
    if [[ -L "$MNT/etc/systemd/system/getty.target.wants/serial-getty@ttyS$SERIAL_UNIT.service" ]]; then
      ok "serial getty enabled for ttyS$SERIAL_UNIT"
    else
      warn "serial getty NOT enabled for ttyS$SERIAL_UNIT — no login prompt on the serial port"
      bad=1
    fi
  fi

  # 4. The initramfs must be able to unlock the pool. Measured failure mode: zero cryptsetup and
  #    zero dropbear entries when CRYPTSETUP=y is absent from conf-hook.
  local initrd listing
  initrd="$(cd "$MNT/boot" && ls initrd.img-* 2>/dev/null | head -1)"
  # NB: `command` is a shell BUILTIN, so `chroot $MNT command -v ...` tries to exec a binary
  # called "command" and always fails — which silently skipped every initramfs check the first
  # time this ran. Use a shell inside the chroot, and fall back to a plain path test.
  if [[ -z "$initrd" ]]; then
    warn "no initrd in /boot — the target cannot boot"
    bad=1
  elif ! chroot "$MNT" sh -c 'command -v lsinitramfs >/dev/null 2>&1' \
       && [[ ! -x "$MNT/usr/bin/lsinitramfs" && ! -x "$MNT/usr/sbin/lsinitramfs" ]]; then
    warn "lsinitramfs unavailable in the target — skipping initramfs checks"
  else
    listing="$(chroot "$MNT" lsinitramfs "/boot/$initrd" 2>/dev/null)"
    local want=(cryptsetup cryptroot dropbear)
    [[ "$CRYPT" == "yes" ]] || want=(dropbear)
    local w
    for w in "${want[@]}"; do
      if grep -q -- "$w" <<<"$listing"; then
        ok "initramfs contains $w"
      else
        warn "initramfs has no '$w' — the machine cannot unlock the pool at boot"
        bad=1
      fi
    done
    grep -q 'dropbear.*_host_key' <<<"$listing" \
      || { warn "initramfs has no dropbear host key — remote unlock will fail"; bad=1; }
  fi

  # 5. crypttab must reference the containers by LUKS UUID, not by a device path,
  # and carry nofail so a missing disk degrades instead of stalling the boot.
  if [[ "$CRYPT" == "yes" ]]; then
    local i
    for (( i = 0; i < ${#DISKS[@]}; i++ )); do
      if grep -qE "^zfs${i}[[:space:]]+UUID=[0-9a-f-]{36}[[:space:]]" "$MNT/etc/crypttab" \
        && grep -qE "^zfs${i}[[:space:]].*nofail" "$MNT/etc/crypttab"; then
        ok "crypttab entry zfs$i is keyed by LUKS UUID (nofail for degraded boot)"
      else
        warn "crypttab entry zfs$i is not keyed by UUID with nofail — a device rename would break the boot"
        bad=1
      fi
    done
  fi

  # 6. The machine must not share the golden image's hostid (ZFS reads it at import).
  if [[ -s "$MNT/etc/hostid" ]]; then
    ok "per-machine /etc/hostid present"
  else
    warn "/etc/hostid missing — the pool may refuse to import on first boot"
    bad=1
  fi

  # NB: the root dataset's `mountpoint` and `canmount` are checked in stage_finish, not here.
  # At this point in the flow the staging mountpoint is *supposed* to still be $MNT, so checking
  # for "/" here fails every correct install.

  # 7. /etc/crypttab is only honoured if systemd-cryptsetup is installed. Debian masks the
  #    legacy cryptdisks.service and cryptdisks-early.service (both symlink to /dev/null), so
  #    with no generator every crypttab entry that the initramfs did not already handle is
  #    silently ignored. The stamp script itself writes such an entry (ephemeral swap).
  if [[ -s "$MNT/etc/crypttab" ]]; then
    if [[ -x "$MNT/usr/lib/systemd/system-generators/systemd-cryptsetup-generator" ]]; then
      ok "systemd-cryptsetup-generator present — /etc/crypttab is honoured at boot"
    else
      warn "systemd-cryptsetup is NOT installed: cryptdisks.service is masked, so /etc/crypttab"
      warn "  is completely inert at boot. Ephemeral swap would never be created (and every"
      warn "  boot would stall ~90s on dev-mapper-swap.device). Add systemd-cryptsetup to"
      warn "  build/golden-packages.list — it is only a Recommends of systemd, and"
      warn "  --variant=important does not install Recommends."
      bad=1
    fi
  fi

  # 8. Memory configuration must match the class. A missing/empty zram config on a server means
  #    no swap at all; a [zram0] section on a mini PC means zram on top of disk swap.
  local zg="$MNT/etc/systemd/zram-generator.conf"
  local zg_has_section=0
  grep -qE '^\[zram0\]' "$zg" 2>/dev/null && zg_has_section=1
  if [[ "$ZRAM" == "yes" ]]; then
    if (( zg_has_section )); then
      if grep -qE '^zram-size[[:space:]]*=[[:space:]]*[0-9]+%' "$zg"; then
        warn "zram-size is a percentage — zram-generator needs an expression like 'ram / 2'"
        warn "  and creates NO device for '50%', which on a server with SWAP=none means no swap"
        bad=1
      else
        ok "zram0 enabled with zram-size = $(sed -n 's/^zram-size *= *//p' "$zg")"
      fi
    else
      warn "ZRAM=yes but $zg has no [zram0] section — the server would boot with NO swap"
      bad=1
    fi
  else
    if (( zg_has_section )); then
      warn "ZRAM=no but $zg still has a [zram0] section — zram would be created anyway"
      bad=1
    else
      ok "zram disabled (no [zram0] section, overriding the vendor default)"
    fi
  fi

  # 9. Network must match the profile. networkd with no .network file does nothing, so a
  #    missing file means no address at boot (this is how DHCP machines lost networking).
  local nw="$MNT/etc/systemd/network/10-wired.network"
  if [[ ! -s "$nw" ]]; then
    warn "10-wired.network missing — systemd-networkd would configure no interface"
    bad=1
  elif [[ "$ADDRESS" == "static" ]]; then
    if grep -qE "^Address=${IPV4}/${CIDR}$" "$nw"; then
      ok "10-wired.network carries static ${IPV4}/${CIDR}"
    else
      warn "10-wired.network has no Address=${IPV4}/${CIDR} line — static IP would not apply"
      bad=1
    fi
  else
    if grep -qE '^DHCP=yes$' "$nw"; then
      ok "10-wired.network enables DHCP"
    else
      warn "10-wired.network has no DHCP=yes — the DHCP machine would boot with no address"
      bad=1
    fi
  fi
  if [[ -L "$MNT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" ]] \
    || [[ -L "$MNT/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" ]]; then
    ok "systemd-networkd enabled"
  else
    warn "systemd-networkd NOT enabled — /etc/systemd/network/10-wired.network would be ignored"
    bad=1
  fi

  # 10. Login user, if the profile asked for one.
  if [[ -n "$USERNAME" ]]; then
    if chroot "$MNT" id "$USERNAME" >/dev/null 2>&1; then
      ok "login user $USERNAME exists"
    else
      warn "USERNAME=$USERNAME set but no such user in the target"
      bad=1
    fi
    if chroot "$MNT" id -nG "$USERNAME" 2>/dev/null | grep -qw sudo; then
      ok "$USERNAME is in the sudo group"
    else
      warn "$USERNAME is NOT in sudo — admin access would fail (is sudo in golden-packages.list?)"
      bad=1
    fi
    if [[ -n "$USER_AUTHORIZED_KEYS" ]]; then
      if [[ -s "$MNT/home/$USERNAME/.ssh/authorized_keys" ]]; then
        ok "$USERNAME has an authorized_keys"
      else
        warn "authorized_keys missing for $USERNAME — SSH login would fail"
        bad=1
      fi
    fi
    pwfield="$(chroot "$MNT" getent shadow "$USERNAME" 2>/dev/null | cut -d: -f2)"
    if [[ -n "$USER_PASSWORD_HASH" ]]; then
      if [[ -n "$pwfield" && "$pwfield" != '!'* && "$pwfield" != '*' ]]; then
        ok "$USERNAME has a password set"
      else
        warn "$USERNAME has no usable password despite USER_PASSWORD_HASH"
        bad=1
      fi
    else
      if [[ "$pwfield" == '!'* || "$pwfield" == '*' || -z "$pwfield" ]]; then
        ok "$USERNAME password locked (SSH-key-only as configured)"
      else
        warn "$USERNAME has a password but none was configured — unexpected"
        bad=1
      fi
    fi
  fi

  if (( bad )); then
    die "target verification FAILED — the machine above would not boot reliably"
  fi
  ok "target verification passed"
}

# Leave the machine in a state that can actually boot. Containers are closed and the md array
# stopped so the disks are quiescent.
#
# An export is still attempted, but it is NOT required: the pool is no longer created with -R,
# so there is no persistent `altroot` to clear, and ZFS is crash-consistent — the target's
# initramfs imports the pool fine from an unclean state. The export is kept because a clean
# export is nicer when it works.
#
# Unmount everything under the staging root, deepest first, then release the ZFS datasets.
#
# THREE traps, all of which had to be found the hard way. Each one on its own leaves `zpool
# export` reporting "pool is busy" with nothing visibly mounted, and only a reboot clears it.
#
#   1. The nested bind mounts from the chroot (dev, proc, sys and their children) DO need
#      `umount`, and `umount -R` is not enough: cgroup2 at /sys/fs/cgroup is held by systemd and
#      refuses a normal unmount, and one refusal aborts the whole recursive unmount, leaving
#      every sibling attached. Unmount them individually, deepest-first, with `-l` as fallback.
#   2. **`zfs unmount -a` SKIPS datasets with `canmount=noauto`.** Verified in the test VM: with
#      canmount=on the dataset is unmounted; with canmount=noauto it is silently left mounted.
#      The staging root is deliberately `canmount=noauto` (it must not auto-mount at boot), so
#      `zfs unmount -a -f` alone never releases it. Datasets must be named explicitly.
#   3. **Never `umount` a ZFS dataset's mountpoint.** `umount` — especially `umount -l` —
#      detaches it without telling ZFS, and the pool is then permanently busy: `zpool export`,
#      `zpool export -f` and `zpool destroy -f` all refuse until reboot. Use `zfs unmount`.
#
# Leaving the root dataset mounted is not merely untidy. `stage_finish` then rewrites its
# `mountpoint` to `/`, so ZFS still thinks the dataset lives at `/` while it is actually mounted
# at $MNT — and `zpool export` tries to unmount `/`. That is the real reason the export failed.
unmount_target() {
  local m f pass
  # Several passes on purpose. ZFS refuses to unmount a dataset while anything is mounted beneath
  # its mountpoint, and the bind mounts do not all disappear in one pass (a stacked dev/pts
  # needs two unmounts, and unmounting /dev takes its children with it). One pass can therefore
  # leave the dataset mounted while reporting no error, and nothing ever retries it.
  for pass in 1 2 3; do
    while read -r m f; do
      [[ -n "$m" ]] || continue
      [[ "$f" == "zfs" ]] && continue
      umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    done < <(awk -v p="$MNT" '$2 ~ ("^" p "(/|$)") { print length, $2, $3 }' /proc/mounts \
               | sort -rn | cut -d' ' -f2-)

    # Explicitly, by name — `zfs unmount -a` skips canmount=noauto, which the staging root is.
    zfs unmount -f "$POOL/ROOT/debian" 2>/dev/null || true
    zfs unmount -f "$POOL/home"        2>/dev/null || true
    zfs unmount -a -f                  2>/dev/null || true

    [[ -z "$(awk -v p="$MNT" '$2 ~ ("^" p "(/|$)") { print $2 }' /proc/mounts)" ]] && break
    sleep 1
  done
}

stage_finish() {
  stage "Finishing (making the target bootable)"

  # Bind mounts from stage_chroot_config FIRST (lazily where necessary), then the datasets.
  unmount_target

  # Say so if anything survived. Silence here is how a bogus "installed" gets reported.
  local left
  left="$(awk -v p="$MNT" '$2 ~ ("^" p "(/|$)") { print $2 }' /proc/mounts | tr '\n' ' ')"
  if [[ -n "${left// /}" ]]; then
    warn "still mounted under $MNT: $left"
    warn "the export below will fail until these are gone"
  fi

  # Restore the final layout now that nothing is mounted, so the target boots with the standard
  # mountpoints. canmount is set before mountpoint to avoid an accidental remount at /.
  zfs set canmount=noauto "$POOL/ROOT/debian" 2>/dev/null || true
  zfs set mountpoint=/ "$POOL/ROOT/debian" 2>/dev/null || true
  zfs set mountpoint=/home "$POOL/home" 2>/dev/null || true
  zfs set canmount=on "$POOL/home" 2>/dev/null || true

  # Now that the layout is final, assert it. The initramfs mounts bootfs with `mount -o zfsutil`,
  # and mount.zfs REFUSES when the requested target does not match the dataset's own `mountpoint`
  # property. Staging sets that property to $MNT, so failing to restore it leaves a machine that
  # unlocks its disks and then drops to an (initramfs) shell with
  #   cannot be mounted at '/root//mnt/inspect' due to canonicalization error
  # Observed exactly this way while testing. This check cannot live in stage_verify: there the
  # staging mountpoint is correct and must still be $MNT.
  if (( APPLY )); then
    local root_mp root_cm
    root_mp="$(zfs get -H -o value mountpoint "$POOL/ROOT/debian" 2>/dev/null)"
    root_cm="$(zfs get -H -o value canmount "$POOL/ROOT/debian" 2>/dev/null)"
    if [[ "$root_mp" == "/" && "$root_cm" == "noauto" ]]; then
      ok "root dataset final layout is mountpoint=/ canmount=noauto"
    else
      die "root dataset is mountpoint='$root_mp' canmount='$root_cm' — must be '/' and 'noauto', or the initramfs cannot mount root"
    fi
  fi

  local pool_left=0
  if (( APPLY )); then
    # zfs-zed holds libzfs handles on imported pools and is a plausible blocker, so stop it: the
    # live medium enables zfs.target (which Wants zfs-zed.service) even though nothing on the
    # medium needs it, and the environment is about to reboot. NOTE: measured, this does NOT
    # fix the export on its own — see the warning below for what is still unknown.
    if systemctl is-active --quiet zfs-zed 2>/dev/null; then
      run systemctl stop zfs-zed
      log "stopped zfs-zed (it holds pool handles)"
      sleep 1
    fi

    # Retry: unmounts can unwind asynchronously, and a mount still detaching keeps the pool busy
    # for a moment.
    local attempt err=""
    for attempt in 1 2 3 4 5; do
      if err="$(zpool export "$POOL" 2>&1)"; then
        log "pool exported"
        break
      fi
      sleep 2
    done
    if zpool list -H -o name 2>/dev/null | grep -qx "$POOL"; then
      pool_left=1
      # NOT fatal: the export only ever existed to clear the persistent `altroot` property, and
      # the pool is no longer created with -R. ZFS is crash-consistent and the target's
      # initramfs imports an unclean pool normally — the stamped machine boots either way,
      # verified. But report it accurately and keep the actual error: a bare "pool is busy" is
      # unactionable, and this has been an unexplained wart for a long time.
      warn "could not export $POOL after 5 attempts: ${err:-unknown error}"
      [[ -n "${left// /}" ]] && warn "cause: mounts still attached under $MNT: $left"
      warn "the target still boots regardless (no altroot, crash-consistent import)"
      warn "to diagnose: zpool status -x; zfs get -H -o name,mounted,mountpoint -r $POOL"
      warn "             dmesg | tail -20; grep -r . /proc/*/cwd 2>/dev/null | grep $MNT"
    fi
  else
    printf '  would run: zpool export %s\n' "$POOL" >&2
  fi

  # Closing a container can only succeed once the pool using it is gone, so when the export
  # above failed this fails too — with a screenful of `device-mapper: remove ioctl ... busy`
  # from cryptsetup's internal udev retry loop. Report the outcome instead of asserting it.
  local m luks_left=0 luks_closed=0
  for m in /dev/mapper/zfs*; do
    [[ -e "$m" ]] || continue
    if run cryptsetup close "$(basename "$m")" 2>/dev/null; then
      luks_closed=$((luks_closed + 1))
    else
      luks_left=$((luks_left + 1))
    fi
  done
  if [[ -e /dev/md0 ]]; then
    run mdadm --stop /dev/md0 2>/dev/null || true
  fi

  if (( ! APPLY )); then
    printf '  would run: cryptsetup close <container>; mdadm --stop /dev/md0\n' >&2
  elif (( pool_left || luks_left )); then
    warn "target finished with the pool still imported and $luks_left container(s) open"
    warn "this is expected to be harmless (the stamped machine boots regardless) — but if you"
    warn "are about to reuse these disks, reboot the live environment first"
  else
    ok "target finished — pool exported, $luks_closed container(s) closed, array stopped"
  fi
}

# Format every ESP. Firmware cannot assemble mdadm, so each disk gets its own ESP; the
# contents are replicated in stage_grub so any single disk can boot the machine alone.
stage_esp() {
  stage "Formatting ESPs"
  ESP_PARTS=()
  ESP_PARTNUMS=()
  ESP_UUID=""
  local d
  for d in "${DISKS[@]}"; do
    resolve_partitions "$d"
    run mkfs.vfat -F32 -n ESP "$PART_ESP"
    ESP_PARTS+=("$PART_ESP")
    ESP_PARTNUMS+=("${PART_ESP##*[!0-9]}")
  done
  if (( APPLY )); then
    ESP_UUID="$(blkid -s UUID -o value "${ESP_PARTS[0]}")"
  fi
  ok "${#ESP_PARTS[@]} ESP(s) formatted"
}

stage_grub() {
  stage "Bootloader on every disk"

  if [[ "$BOOT_MODE" != "uefi" ]]; then
    local d
    for d in "${BOOT_DISKS[@]}"; do
      run grub-install --target=i386-pc --boot-directory="$MNT/boot" --recheck "$d"
    done
    ok "GRUB (BIOS core.img) installed on ${#BOOT_DISKS[@]} disk(s)"
  fi

  if [[ "$BOOT_MODE" != "bios" ]]; then
    run mkdir -p "$MNT/boot/efi"
    run mount "${ESP_PARTS[0]}" "$MNT/boot/efi"

    # Install GRUB into the first ESP, then replicate that ESP onto every other disk and
    # register a firmware entry for each, so any single disk can boot the machine alone.
    run chroot "$MNT" grub-install --target=x86_64-efi \
      --efi-directory=/boot/efi --bootloader-id=debian --recheck

    # Also install the removable-media fallback at /EFI/BOOT/BOOTX64.EFI. The efibootmgr
    # entries created below live in the machine's NVRAM; without a fallback the disk will not
    # boot on firmware that has no entry for it — a replaced disk, cleared NVRAM, or a machine
    # that never saw the original install. This is what makes the disk self-contained.
    run chroot "$MNT" grub-install --target=x86_64-efi \
      --efi-directory=/boot/efi --bootloader-id=debian --removable --recheck

    local i esp_tmp=/tmp/esp-replicate
    run mkdir -p "$esp_tmp"
    for (( i = 1; i < ${#ESP_PARTS[@]}; i++ )); do
      run mount "${ESP_PARTS[$i]}" "$esp_tmp"
      run rsync -a --delete "$MNT/boot/efi/" "$esp_tmp/"
      run umount "$esp_tmp"
      ok "ESP replicated to ${ESP_PARTS[$i]}"
    done

    if (( APPLY )); then
      for (( i = 0; i < ${#ESP_PARTS[@]}; i++ )); do
        efibootmgr --create \
          --disk "${DISKS[$i]}" \
          --part "${ESP_PARTNUMS[$i]}" \
          --label "debian (${DISKS[$i]##*/})" \
          --loader '\EFI\debian\grubx64.efi'
      done
    else
      printf '  would create one EFI boot entry per disk\n' >&2
    fi
    # The ESP deliberately stays mounted across update-grub below (so grub-mkconfig sees the
    # real /boot/efi) and is unmounted in stage_finish.
    ok "GRUB (UEFI) installed and replicated to ${#ESP_PARTS[@]} ESP(s)"
  fi

  # THE step that makes the machine bootable. grub-install only lays down the bootloader and its
  # modules — it does NOT write /boot/grub/grub.cfg. Without grub-mkconfig, GRUB finds no menu,
  # falls back to its own command prompt, and the machine never starts. This must run AFTER
  # stage_chroot_config has written /etc/default/grub.d/99-zfs-stamp.cfg, because that file is
  # what carries root=ZFS=, nohibernate, zswap and the serial console onto the kernel line.
  run chroot "$MNT" update-grub

  if (( APPLY )); then
    if [[ -s "$MNT/boot/grub/grub.cfg" ]]; then
      # update-grub on a ZFS root derives `root=ZFS=<pool>/ROOT/<dataset>` from the mounted
      # root; check it landed, it is the one thing the initramfs cannot guess wrong.
      grep -q "root=ZFS=$POOL/ROOT/debian" "$MNT/boot/grub/grub.cfg" \
        || die "update-grub ran but grub.cfg has no root=ZFS=$POOL/ROOT/debian — refusing to report success on an unbootable target"
      ok "grub.cfg generated ($(grep -c '^menuentry' "$MNT/boot/grub/grub.cfg") menu entries)"
    else
      die "update-grub did not produce /boot/grub/grub.cfg — the target would not boot"
    fi
  fi
}

# --------------------------------------------------------------------------- main

main() {
  validate_profile
  show_plan
  preflight
  confirm_disks

  stage_partition
  stage_boot
  stage_esp
  stage_luks
  stage_pool
  stage_recv
  stage_boot_payload
  stage_chroot_config
  stage_dropbear
  stage_user
  # grub-install needs the chroot's /dev, so it must run BEFORE stage_initramfs unmounts it.
  stage_grub
  stage_initramfs
  stage_verify
  stage_finish

  stage "Done"
  if (( APPLY )); then
    ok "installed '$PROFILE_NAME' onto ${#DISKS[@]} disk(s)"
    log "next: unmount, export the pool, reboot, confirm dropbear unlock, then run the acceptance gate (DESIGN.md §14)"
  else
    ok "dry run complete — re-run with --apply to install"
  fi
}

# Never leave the target half-mounted. If any stage aborts, stage_initramfs never runs and its
# unmount never happens — leaving /dev, /proc and /sys bind-mounted into the target, which then
# blocks mdadm and the pool from being torn down.
cleanup_on_exit() {
  if (( APPLY )); then
    umount "$MNT/boot/efi" 2>/dev/null || true
    for fs in sys proc dev/pts dev; do umount -R "$MNT/$fs" 2>/dev/null || true; done
  fi
}
trap cleanup_on_exit EXIT

main "$@"
