#!/bin/sh
# mount-carrier.sh — find the carrier partition by label and mount it.
#
# The carrier holds the golden stream, the boot payload and the per-host
# profiles (see build/iso-readme.txt). Its partition is labelled CARRIER, but
# its device name (sda/sdb/...) is not stable across machines — so look it up
# by label instead of guessing.
#
#   sudo /root/mount-carrier.sh [LABEL] [mountpoint]
#
# Defaults: LABEL=CARRIER, mountpoint=/media/carrier. Idempotent: exits 0 at
# once if the mountpoint is already mounted. Waits briefly for slow USB.

set -eu

LABEL="${1:-CARRIER}"
MNT="${2:-/media/carrier}"
BYLABEL="${BYLABEL:-/dev/disk/by-label}"
WAIT_SECS="${WAIT_SECS:-15}"

die()  { printf 'mount-carrier: ERROR: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'mount-carrier: %s\n' "$*" >&2; }

if mountpoint -q "$MNT" 2>/dev/null; then
  ok "$MNT is already mounted:"
  ls "$MNT" >&2
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  die "mounting needs root — re-run with sudo"
fi
mkdir -p "$MNT"

# Wait for the label to appear (USB settle after plug-in).
i=0
while [ ! -e "$BYLABEL/$LABEL" ] && [ "$i" -lt "$WAIT_SECS" ]; do
  sleep 1
  i=$((i + 1))
done
[ -e "$BYLABEL/$LABEL" ] \
  || die "no partition labelled '$LABEL' appeared within ${WAIT_SECS}s (is the carrier plugged in?)"

DEV="$(readlink -f "$BYLABEL/$LABEL")"
ok "carrier is $DEV (label $LABEL)"
mount "$DEV" "$MNT" || die "mount $DEV -> $MNT failed"

ok "mounted at $MNT:"
ls "$MNT" >&2
# Nudge on missing payload — the installer cannot do anything without it.
for f in rpool.stream.zst boot.tar.zst; do
  [ -e "$MNT/$f" ] || printf 'mount-carrier: WARN: %s missing from the carrier\n' "$f" >&2
done
if ! ls "$MNT"/*.conf >/dev/null 2>&1; then
  printf 'mount-carrier: WARN: no *.conf profile on the carrier\n' >&2
fi
