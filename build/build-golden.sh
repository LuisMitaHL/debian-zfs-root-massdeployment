#!/usr/bin/env bash
# build-golden.sh — build the golden Debian 13 root-on-ZFS image on the Arch build host.
#
# Produces:
#   $OUT/rpool.stream.zst   the golden root dataset, for `zfs recv` on the target
#   $OUT/boot.tar.zst       the kernel payload for the ext4 /boot that lives OUTSIDE the pool
#
# How it works: a file-backed ZFS pool literally named `rpool` is created on the host, so the
# dataset paths in the stream match the target's exactly (rpool, rpool/ROOT/debian, rpool/home).
# mmdebstrap runs inside a Debian container with that dataset bind-mounted as its target.
#
#   ./build/build-golden.sh                 # build (mmdebstrap in a Docker container)
#   ./build/build-golden.sh --native        # run mmdebstrap directly (Debian host / VM test)
#   ./build/build-golden.sh --clean         # destroy the build pool afterwards
#
# STATUS: first draft, never executed. Run build/verify-host.sh first.

set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$REPO/out}"
WORK="${GOLDEN_WORK:-/var/tmp/zfs-golden}"
IMG="$WORK/rpool.img"
IMG_SIZE="${IMG_SIZE:-16G}"
POOL="rpool"
MNT="$WORK/mnt"
SNAP="golden-$(date -u +%Y%m%dT%H%M%SZ)"
SUITE="trixie"
CONTAINER_IMAGE="debian:trixie"
DEBIAN_MIRROR="http://deb.debian.org/debian"

CLEAN=0
NATIVE=0
for arg in "$@"; do
  case "$arg" in
    --clean)  CLEAN=1 ;;
    --native) NATIVE=1 ;;
    -h|--help)
      sed -n '2,14p' "${BASH_SOURCE[0]}" >&2
      exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 1 ;;
  esac
done
MODE=$([[ "$NATIVE" -eq 1 ]] && echo "native" || echo "container")

log()  { printf '[build-golden] %s\n' "$*" >&2; }
warn() { printf '[build-golden] WARN: %s\n' "$*" >&2; }
die()  { printf '[build-golden] ERROR: %s\n' "$*" >&2; exit 1; }

stage() { printf '\n== %s ==\n' "$*" >&2; }

# --------------------------------------------------------------------- instance lock

# One builder at a time: two concurrent runs would share $WORK/$IMG and the pool
# name `rpool`. flock (not a pidfile) so a killed run releases the lock by itself.
mkdir -p "$WORK" "$OUT"
command -v flock >/dev/null || die "flock not found (util-linux required)"
exec {GOLDEN_LOCK_FD}>"$WORK/.build-golden.lock"
if ! flock -n "$GOLDEN_LOCK_FD"; then
  holder="$(cat "$WORK/.build-golden.pid" 2>/dev/null || echo unknown)"
  die "another build-golden.sh is already running (pid $holder) — refusing to share $WORK"
fi
echo "$$" > "$WORK/.build-golden.pid"

# Stale state from a killed run: mounts left under $MNT, our own file-backed pool
# still imported, and a non-empty $MNT that makes `zpool create -R` abort with
# "mountpoint exists and is not empty". Safe to reclaim here precisely because the
# lock above proves no other instance is running.
reclaim_stale_state() {
  local m f
  # Release mounts under $MNT first (bind leftovers from a dead mmdebstrap run).
  while read -r m f; do
    [[ -n "$m" ]] || continue
    if [[ "$f" == "zfs" ]]; then
      zfs unmount -f "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    else
      umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    fi
  done < <(awk -v p="$MNT" '$2 ~ ("^" p "(/|$)") { print length, $2, $3 }' /proc/mounts \
             | sort -rn | cut -d' ' -f2-)

  # Our own stale pool (file-backed on $IMG) may still be imported. Destroy it —
  # but ONLY if its vdev really is our image file; anything else is someone's
  # real pool and must not be touched.
  if zpool list -H -o name 2>/dev/null | grep -qx "$POOL"; then
    command -v zdb >/dev/null \
      || die "zdb not found — cannot verify who owns pool '$POOL', refusing to proceed"
    if zdb -C "$POOL" 2>/dev/null | grep -qF "$IMG"; then
      warn "destroying our own stale build pool '$POOL' from a previous run"
      zpool destroy -f "$POOL" 2>/dev/null \
        || die "could not destroy stale build pool '$POOL' — reboot the host, then re-run"
    else
      die "a pool named '$POOL' already exists on this host and is NOT our build pool — refusing to touch it"
    fi
  fi

  # Whatever is left in $MNT now is stale build output, not a live mount.
  if [[ -d "$MNT" ]] && [[ -n "$(ls -A "$MNT" 2>/dev/null)" ]]; then
    if awk -v p="$MNT" '$2 ~ ("^" p "(/|$)") { found=1 } END { exit !found }' /proc/mounts; then
      die "something is still mounted under $MNT — unmount it by hand, then re-run"
    fi
    warn "clearing stale contents of $MNT from a previous run"
    rm -rf -- "${MNT:?}/"?* "${MNT:?}/".[!.]* 2>/dev/null || true
    [[ -z "$(ls -A "$MNT" 2>/dev/null)" ]] \
      || die "could not clear $MNT — clear it by hand, then re-run"
  fi
  mkdir -p "$MNT"
}

# --------------------------------------------------------------------- preflight

stage "Preflight"
command -v zpool >/dev/null || die "zpool not found (is ZFS loaded on this host?)"
if [[ "$NATIVE" -eq 1 ]]; then
  command -v mmdebstrap >/dev/null || die "mmdebstrap not found (required in --native mode)"
  zpool list >/dev/null 2>&1 || die "zpool is not usable — is /dev/zfs present?"
else
  command -v docker >/dev/null || die "docker not found"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"
fi

if zpool list -H -o name 2>/dev/null | grep -qx "$POOL"; then
  log "a pool named '$POOL' exists — reclaim will keep it only if it is ours"
fi

# A killed run leaves mounts, our own stale pool, and a non-empty $MNT behind.
# Reclaim runs under the instance lock above, so no other builder can exist.
reclaim_stale_state

# --------------------------------------------------------------------- build pool

stage "Creating file-backed build pool '$POOL' ($IMG_SIZE)"
if [[ ! -f "$IMG" ]]; then
  truncate -s "$IMG_SIZE" "$IMG"
fi
zpool create -f \
  -o ashift=12 \
  -O compression=zstd \
  -O acltype=posixacl \
  -O xattr=sa \
  -O dnodesize=auto \
  -O normalization=formD \
  -O relatime=on \
  -O canmount=off \
  -O mountpoint=/ \
  -R "$MNT" \
  "$POOL" "$IMG"

zfs create -o canmount=off -o mountpoint=/ "$POOL/ROOT"
zfs create -o canmount=noauto -o mountpoint=/ "$POOL/ROOT/debian"
zfs create -o mountpoint=/home "$POOL/home"
zfs mount "$POOL/ROOT/debian"

log "build root is at $MNT (dataset $POOL/ROOT/debian)"

# --------------------------------------------------------------------- bootstrap

stage "Bootstrapping Debian $SUITE with mmdebstrap (${MODE} mode)"
INCLUDE="$(grep -vE '^\s*(#|$)' "$REPO/build/golden-packages.list" | paste -sd, -)"
log "included packages: $(printf '%s' "$INCLUDE" | tr ',' '\n' | wc -l)"

if [[ "$NATIVE" -eq 1 ]]; then
  # Native mode: this host is already Debian, so run mmdebstrap directly. Used for testing
  # the build inside a throwaway VM, and useful for anyone building on a Debian host.
  command -v mmdebstrap >/dev/null || die "mmdebstrap not installed (native mode)"
  REPO_DIR="$REPO" mmdebstrap \
    --variant=important \
    --components="main contrib" \
    --include="$INCLUDE" \
    --customize-hook="$REPO/build/golden-customize.sh \"\$1\"" \
    "$SUITE" "$MNT" "$DEBIAN_MIRROR"
else
  docker run --rm --privileged \
    -v "$REPO:/work:ro" \
    -v "$MNT:/target" \
    -e DEBIAN_FRONTEND=noninteractive \
    -e REPO_DIR=/work \
    "$CONTAINER_IMAGE" \
    bash -euo pipefail -c '
      echo "==> installing mmdebstrap"
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends mmdebstrap ca-certificates

      echo "==> running mmdebstrap"
      mmdebstrap \
        --variant=important \
        --components="main contrib" \
        --include="'"$INCLUDE"'" \
        --customize-hook="/work/build/golden-customize.sh \"\$1\"" \
        "'"$SUITE"'" /target "'"$DEBIAN_MIRROR"'"
    '
fi

# --------------------------------------------------------------------- verify

stage "Verifying the built image"
# DKMS lands in lib/modules/<kver>/updates/dkms/, not the in-tree kernel/zfs/ path.
# Search both, and both /lib and /usr/lib because of usr-merge.
first_mod="$(find "$MNT/lib/modules" "$MNT/usr/lib/modules" \
               -name 'zfs.ko*' -print -quit 2>/dev/null || true)"
if [[ -z "$first_mod" ]]; then
  die "no zfs.ko anywhere in the golden image — DKMS did not build. Do NOT ship this image."
fi
log "zfs.ko present: ${first_mod#"$MNT"}"

if [[ -s "$MNT/etc/machine-id" ]]; then
  die "/etc/machine-id is not empty in the golden image — identity would be cloned"
fi
log "identity is clean (empty machine-id, no host keys)"

# /boot lives outside the pool, so its payload travels separately.
stage "Packing the /boot payload"
tar --zstd -cf "$OUT/boot.tar.zst" -C "$MNT/boot" .
log "wrote $OUT/boot.tar.zst"

# mmdebstrap's chroot leaves bind mounts behind (/proc, /sys, /dev, and everything under them).
#
# Three traps, all verified in the test VM. Any one of them leaves the pool permanently busy —
# `zpool export`, `zpool export -f` and `zpool destroy -f` all refuse until the machine is
# rebooted, which is why every golden build used to end with "could not destroy the build pool".
#
#   1. `umount -R` is not enough, and it fails quietly: cgroup2 at $MNT/sys/fs/cgroup is held by
#      systemd and refuses a normal unmount, and when ONE child of a recursive unmount refuses
#      the whole recursive unmount aborts, leaving /sys, /proc and /dev attached.
#   2. `zfs unmount -a` SKIPS datasets with `canmount=noauto`. This pool's root is exactly that,
#      so it is named explicitly.
#   3. Never `umount` a ZFS dataset's mountpoint: `umount -l` detaches it without telling ZFS
#      and poisons the pool for good. Datasets go through `zfs unmount`.
cleanup_target_mounts() {
  local m f pass left
  # Several passes: ZFS refuses to unmount a dataset while anything is mounted beneath its
  # mountpoint, and the bind mounts do not all disappear in one pass (stacked dev/pts needs two
  # unmounts; unmounting /dev takes its children with it). One pass can therefore leave the
  # dataset mounted while reporting no error, and nothing retries it.
  for pass in 1 2 3; do
    while read -r m f; do
      [[ -n "$m" ]] || continue
      [[ "$f" == "zfs" ]] && continue
      umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    done < <(awk -v p="$MNT" '$2 ~ ("^" p "(/|$)") { print length, $2, $3 }' /proc/mounts \
               | sort -rn | cut -d' ' -f2-)

    zfs unmount -f "$POOL/ROOT/debian" 2>/dev/null || true
    zfs unmount -f "$POOL/ROOT"        2>/dev/null || true
    zfs unmount -f "$POOL/home"        2>/dev/null || true
    zfs unmount -a -f                  2>/dev/null || true

    [[ -z "$(awk -v p="$MNT" '$2 ~ ("^" p "(/|$)") { print $2 }' /proc/mounts)" ]] && break
    sleep 1
  done

  left="$(awk -v p="$MNT" '$2 ~ ("^" p "(/|$)") { print $2 }' /proc/mounts | tr '\n' ' ')"
  if [[ -n "${left// /}" ]]; then
    warn "still mounted under $MNT: $left"
    warn "the pool export/destroy below will fail until these are gone"
  fi
}

# --------------------------------------------------------------------- send

stage "Snapshotting and sending"
cleanup_target_mounts
zfs umount "$POOL/ROOT/debian" 2>/dev/null || true
zfs snapshot -r "$POOL@$SNAP"
zfs send -R "$POOL@$SNAP" | zstd -T0 -19 > "$OUT/rpool.stream.zst"
log "wrote $OUT/rpool.stream.zst ($(du -h "$OUT/rpool.stream.zst" | cut -f1))"

zfs list -r "$POOL" >&2

# --------------------------------------------------------------------- cleanup

if (( CLEAN )); then
  stage "Cleaning up the build pool (the stream and boot payload are kept)"
  cleanup_target_mounts
  zfs unmount -a -f 2>/dev/null || true
  # Retry: a lazy unmount detaches asynchronously, and a mount still unwinding keeps the pool
  # busy for a moment.
  exported=0
  for _ in 1 2 3 4 5; do
    if zpool export "$POOL" 2>/dev/null; then exported=1; break; fi
    sleep 2
  done
  if (( ! exported )) && zpool destroy -f "$POOL" 2>/dev/null; then exported=1; fi
  if (( exported )); then
    rm -f "$IMG"
    log "build pool destroyed"
  else
    warn "could not destroy the build pool '$POOL'"
    warn "the next run will reclaim it automatically (stale mounts + non-empty $MNT included)"
    warn "as long as no other build-golden.sh is running — otherwise reboot the host first"
  fi
else
  log "build pool kept for incremental rebuilds; re-run with --clean to remove it"
fi

stage "Done"
cat >&2 <<EOF
  golden stream : $OUT/rpool.stream.zst
  boot payload  : $OUT/boot.tar.zst

  Copy both to the carrier medium, then build the live installer:
    ./build/build-live.sh
EOF
