#!/usr/bin/env bash
# pick-disks.sh — fill the DISKS=() array of a zfs-stamp profile from /dev/disk/by-id.
#
# Editing a hostname or an IP by hand is cheap; retyping a full by-id path is slow
# and error-prone. This lists the machine's whole disks (numbered, with size and
# model), reads a multi-selection, and rewrites the DISKS block in place.
#
#   ./pick-disks.sh <profile.conf> [by-id-path ...]
#
# With paths: set directly, no menu. Without: interactive menu ("1 3", "1-2", "all").
# A backup is left at <profile>.bak. Shipped at /root/pick-disks.sh on the live ISO:
#   sudo /root/pick-disks.sh /media/carrier/<host>.conf

set -Eeuo pipefail

BYID="${BYID:-/dev/disk/by-id}"

die()  { printf 'pick-disks: ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'pick-disks: WARN: %s\n' "$*" >&2; }
ok()   { printf 'pick-disks: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: pick-disks.sh <profile.conf> [by-id-path ...]
  Lists whole disks from /dev/disk/by-id, reads a selection ("1 3", "1-2", "all"),
  and rewrites the DISKS=(...) block in the profile (backup: <profile>.bak).
  With by-id paths given, sets them directly with no menu.
EOF
  exit "${1:-2}"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0
(( $# >= 1 )) || usage

PROFILE="$1"; shift
[[ -f "$PROFILE" ]] || die "no such profile: $PROFILE"
[[ -w "$PROFILE" ]] || die "$PROFILE is not writable — run with sudo"
grep -qE '^[[:space:]]*DISKS=\(' "$PROFILE" \
  || die "$PROFILE has no DISKS=(...) block to rewrite"

[[ -d "$BYID" ]] || die "$BYID not found — no by-id device names on this machine"

# --- whole-disk candidates, deduplicated by device node -----------------------
# One disk has many by-id aliases (ata-*, wwn-*, ...); group them and show one
# line per disk. Partitions (-partN), mapper/md/lvm names and optical media
# are never whole-disk targets.

declare -A NODE_ALIASES=()   # /dev/node -> "alias1 alias2 ..."
declare -A NODE_INFO=()      # /dev/node -> "TYPE|SIZE|MODEL|TRAN|RM" (may be empty)

HAVE_LSBLK=1
command -v lsblk >/dev/null 2>&1 || HAVE_LSBLK=0
(( HAVE_LSBLK )) || warn "lsblk not found — listing by name only, sizes unknown"

declare -i N_TOTAL=0 N_DANGLING=0 N_FILTERED=0 N_REJECTED=0 N_LSBLK_OUT=0
SAMPLE_REJECT=""

discover() {
  # $1 = 1 to consult lsblk, 0 for name-heuristic fallback (no sizes, no checks).
  local use_lsblk="$1"
  local p b node info
  for p in "$BYID"/*; do
    # NOTE: entries here are *always* symlinks — that is normal. A symlink whose
    # target does not exist in this namespace (dangling) is unusable: skip it.
    N_TOTAL=$((N_TOTAL + 1))
    b="${p##*/}"
    case "$b" in
      *-part[0-9]*|dm-*|md-*|lvm-*|*DVD*|*CD-ROM*|*cdrom*)
        N_FILTERED=$((N_FILTERED + 1)); continue ;;
    esac
    node="$(readlink -f "$p")"
    if [[ ! -e "$node" ]]; then
      N_DANGLING=$((N_DANGLING + 1)); continue
    fi
    info=""
    if (( use_lsblk )); then
      info="$(lsblk -dnro TYPE,SIZE,MODEL,TRAN,RM "$node" 2>/dev/null || true)"
      [[ -n "$info" ]] && N_LSBLK_OUT=$((N_LSBLK_OUT + 1))
      # Whole disks only — but take multipath nodes too (TYPE=mpath), they are
      # stampable block devices just like plain disks.
      case "${info%%|*}" in
        disk|mpath) ;;
        *) N_REJECTED=$((N_REJECTED + 1))
           [[ -z "$SAMPLE_REJECT" ]] && SAMPLE_REJECT="$b -> $node (lsblk: '${info:-no output}')"
           continue ;;
      esac
    fi
    NODE_ALIASES["$node"]+="$b "
    NODE_INFO["$node"]="$info"
  done
}

discover "$HAVE_LSBLK"

# lsblk answered nothing at all (missing columns on an old util-linux, broken
# output) while real entries survived filtering: its verdicts are worthless, so
# retry by name rather than reporting an empty machine.
if ((${#NODE_ALIASES[@]} == 0 && HAVE_LSBLK && N_LSBLK_OUT == 0 && N_TOTAL - N_FILTERED - N_DANGLING > 0)); then
  warn "lsblk produced no usable output — falling back to names only (sizes unknown, type unchecked)"
  N_TOTAL=0; N_DANGLING=0; N_FILTERED=0; N_REJECTED=0; SAMPLE_REJECT=""
  discover 0
fi

if ((${#NODE_ALIASES[@]} == 0)); then
  die "no whole disks found under $BYID ($N_TOTAL entries: $N_DANGLING dangling, $N_FILTERED partition/mapper names, $N_REJECTED rejected by lsblk${SAMPLE_REJECT:+ — e.g. $SAMPLE_REJECT})"
fi

# Prefer stable, human-meaningful aliases; raw wwn/eui identifiers sort last.
alias_rank() {
  case "$1" in
    ata-*)     echo 1 ;;
    nvme-eui.*|eui.*) echo 8 ;;
    nvme-*)    echo 2 ;;
    usb-*)     echo 3 ;;
    virtio-*|mmc-*|memstick-*) echo 4 ;;
    scsi-*)    echo 5 ;;
    wwn-*)     echo 7 ;;
    *)         echo 9 ;;
  esac
}

mapfile -t NODES < <(printf '%s\n' "${!NODE_ALIASES[@]}" | sort)
declare -a MENU_ALIAS=() MENU_NODE=()

i=0
for node in "${NODES[@]}"; do
  i=$((i + 1))
  best=""; best_rank=99
  # shellcheck disable=SC2086
  for a in ${NODE_ALIASES["$node"]}; do
    r="$(alias_rank "$a")"
    if (( r < best_rank )); then best="$a"; best_rank="$r"; fi
  done
  MENU_ALIAS+=("$BYID/$best")
  MENU_NODE+=("$node")
  info="${NODE_INFO["$node"]}"
  rest="${info#*|}"; size="${rest%%|*}"; rest="${rest#*|}"
  model="${rest%%|*}"; rest="${rest#*|}"
  tran="${rest%%|*}"; rm_flag="${rest##*|}"
  # shellcheck disable=SC1083
  printf '  %2d) %-60s %-5s %-22s %s\n' \
    "$i" "$BYID/$best" "(${node##*/})" "${size:-?}" "${model:-unknown}${tran:+ [$tran]}${rm_flag:+ rm=$rm_flag}"
done >&2

# --- selection ----------------------------------------------------------------
declare -a PICKED=()

parse_selection() {
  local input="$1" count="$2"
  local -a nums=()
  local tok a b n
  input="${input//,/ }"
  for tok in $input; do
    if [[ "$tok" == "all" ]]; then
      for (( n = 1; n <= count; n++ )); do nums+=("$n"); done
    elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
      (( a >= 1 && b <= count && a <= b )) || return 1
      for (( n = a; n <= b; n++ )); do nums+=("$n"); done
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      (( tok >= 1 && tok <= count )) || return 1
      nums+=("$tok")
    else
      return 1
    fi
  done
  ((${#nums[@]})) || return 1
  mapfile -t PICKED < <(printf '%s\n' "${nums[@]}" | sort -nu)
}

if (($#)); then
  # Direct mode: every argument must be an existing whole-disk by-id path.
  n=0
  for p in "$@"; do
    [[ -e "$p" ]] || die "not found: $p"
    [[ "$p" == "$BYID"/* ]] || die "not a by-id path: $p (want $BYID/*)"
    case "${p##*/}" in *-part[0-9]*) die "not a whole disk (partition): $p" ;; esac
    found=0
    for m in "${MENU_ALIAS[@]}"; do [[ "$m" == "$p" ]] && found=1; done
    (( found )) || warn "$p is not a recognised whole disk — writing it anyway"
    PICKED+=("$p"); n=$((n + 1))
  done
else
  sel=""
  while true; do
    read -rp "Select disk(s) [numbers, ranges, 'all', q to quit]: " sel || die "aborted (no selection read)"
    [[ "$sel" == "q" ]] && die "aborted"
    if parse_selection "$sel" "$i"; then break; fi
    warn "invalid selection — try e.g. '1 3', '1-2', or 'all'"
  done
  declare -a paths=()
  for n in "${PICKED[@]}"; do paths+=("${MENU_ALIAS[$((n - 1))]}"); done
  PICKED=("${paths[@]}")
fi

# --- safety: the carrier USB itself shows up as a usb/removable disk -----------
declare -a risky=()
for idx in "${!MENU_ALIAS[@]}"; do
  for p in "${PICKED[@]}"; do
    if [[ "$p" == "${MENU_ALIAS[$idx]}" ]]; then
      info="${NODE_INFO["${MENU_NODE[$idx]}"]}"
      tran="${info##*|}"; tran="${tran%|*}"
      rm_flag="${info##*|}"
      if [[ "$tran" == "usb" || "$rm_flag" == "1" ]]; then
        risky+=("$p (removable — often the carrier USB itself)")
      fi
    fi
  done
done
if ((${#risky[@]})); then
  printf 'pick-disks: WARN: selected device(s) look removable:\n' >&2
  printf '  %s\n' "${risky[@]}" >&2
  if [[ -t 0 ]]; then
    read -rp "Continue anyway? [y/N]: " yn || die "aborted"
    [[ "$yn" == "y" || "$yn" == "Y" ]] || die "aborted"
  fi
fi

# --- light profile-shape checks (zfs-stamp.sh enforces the rest) ---------------
topology="$(sed -n 's/^TOPOLOGY="\([^"]*\)".*/\1/p' "$PROFILE" | head -1)"
class="$(sed -n 's/^CLASS="\([^"]*\)".*/\1/p' "$PROFILE" | head -1)"
if [[ "$topology" == "single" && "${#PICKED[@]}" -ne 1 ]]; then
  die "TOPOLOGY=single needs exactly 1 disk, got ${#PICKED[@]}"
fi
if [[ "$class" == "mini" && "${#PICKED[@]}" -ne 1 ]]; then
  die "CLASS=mini needs exactly 1 disk, got ${#PICKED[@]}"
fi
if [[ "$topology" == "mirror" && "${#PICKED[@]}" -lt 2 ]]; then
  die "TOPOLOGY=mirror needs at least 2 disks, got ${#PICKED[@]}"
fi

# --- rewrite the DISKS block ----------------------------------------------------
repl=""
for p in "${PICKED[@]}"; do repl+="  $p"$'\n'; done
repl="${repl%$'\n'}"

cp -f "$PROFILE" "$PROFILE.bak"
tmp="$(mktemp)"
if ! awk -v repl="$repl" '
  BEGIN { inblock = 0; done = 0 }
  !done && /^[[:space:]]*DISKS=\(/ {
    if ($0 ~ /\)[[:space:]]*(#.*)?$/) { print "DISKS=("; print repl; print ")"; done = 1; next }
    print "DISKS=("; print repl; inblock = 1; next
  }
  inblock && /^[[:space:]]*\)/ { print ")"; inblock = 0; done = 1; next }
  inblock { next }
  { print }
  END { if (!done) exit 1 }
' "$PROFILE" > "$tmp"; then
  rm -f "$tmp"
  die "could not rewrite DISKS block (profile untouched, backup kept at $PROFILE.bak)"
fi
cat "$tmp" > "$PROFILE"
rm -f "$tmp"

ok "wrote ${#PICKED[@]} disk(s) to $PROFILE (backup: $PROFILE.bak):"
printf '  %s\n' "${PICKED[@]}" >&2
ok "hostname/IP are still yours to edit — only DISKS changed"
