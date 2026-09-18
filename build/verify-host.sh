#!/usr/bin/env bash
# verify-host.sh — check that the build host can actually build the golden image and the
# live install medium.
#
# The two things that can only fail at the very end of a long pipeline are:
#   1. live-build needs to create loop devices and mount filesystems to assemble the ISO.
#   2. mmdebstrap/live-build run inside a Debian container, so container privileges matter.
# This script checks both up front. Run it before building anything.
#
#   ./build/verify-host.sh
#
# Exit code 0 = all checks passed. Non-zero = at least one FAIL.

set -Eeuo pipefail

PASS=0
FAIL=0
WARN=0
declare -a RESULTS=()

pass() { RESULTS+=("PASS  $1"); PASS=$((PASS + 1)); }
fail() { RESULTS+=("FAIL  $1"); FAIL=$((FAIL + 1)); }
warn() { RESULTS+=("WARN  $1"); WARN=$((WARN + 1)); }
info() { RESULTS+=("INFO  $1"); }

have() { command -v "$1" >/dev/null 2>&1; }

section() { printf '\n== %s ==\n' "$1" >&2; }

# --------------------------------------------------------------------------- host

section "Host"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "distro: ${PRETTY_NAME:-unknown} (kernel $(uname -r))"
  if [[ "${ID:-}" != "arch" ]]; then
    warn "expected an Arch build host; this is '${ID:-unknown}'. Not fatal — only the container matters."
  fi
else
  warn "cannot read /etc/os-release"
fi

if [[ "$(id -u)" -eq 0 ]]; then
  info "running as root"
else
  warn "not running as root — the loop-device probe needs root; run with sudo for a complete check"
fi

# --------------------------------------------------------------------------- container runtime

section "Container runtime"
if have docker; then
  if docker info >/dev/null 2>&1; then
    pass "docker daemon reachable ($(docker info --format '{{.ServerVersion}}' 2>/dev/null))"
  else
    fail "docker binary present but the daemon is NOT reachable (no /var/run/docker.sock?)"
  fi
elif have podman; then
  pass "podman present (rootless podman may still need privileges for loop mounts)"
elif have systemd-nspawn; then
  warn "only systemd-nspawn found; workable but Docker/Podman is the happier path"
else
  fail "no container runtime found (docker, podman or systemd-nspawn)"
fi

# --------------------------------------------------------------------------- loop devices

section "Loop devices and mounts (the ISO-assembly blocker)"

# live-build runs inside a privileged container, so the loop probe must run THERE too.
# Probing /dev of the invoking namespace gives a false negative inside a restricted sandbox,
# because that /dev is a container-local tmpfs rather than the host's devtmpfs.
LOOP_PROBE_IMG="${LOOP_PROBE_IMAGE:-alpine}"

probe_loop_in_container() {
  # Single quotes are deliberate: $D must expand inside the container, not on the host.
  # shellcheck disable=SC2016
  timeout 180 docker run --rm --privileged "$LOOP_PROBE_IMG" sh -c '
    dd if=/dev/zero of=/tmp/probe bs=1M count=8 2>/dev/null || exit 1
    D=$(losetup -f 2>/dev/null) || exit 1
    [ -n "$D" ] || exit 1
    losetup "$D" /tmp/probe 2>/dev/null || exit 1
    losetup -d "$D" 2>/dev/null || exit 1
  ' >/dev/null 2>&1
}

probe_loop_on_host() {
  [[ "$(id -u)" -eq 0 ]] || return 2
  [[ -e /dev/loop-control ]] || return 1
  local f d
  f="$(mktemp /tmp/loop-probe.XXXXXX)"
  dd if=/dev/zero of="$f" bs=1M count=8 status=none 2>/dev/null || { rm -f "$f"; return 1; }
  if d="$(losetup --find --show "$f" 2>/dev/null)" && [[ -n "$d" ]]; then
    losetup -d "$d" 2>/dev/null || true
    rm -f "$f"
    return 0
  fi
  rm -f "$f"
  return 1
}

if docker info >/dev/null 2>&1; then
  if probe_loop_in_container; then
    pass "privileged container can attach a loop device — live-build can assemble an ISO"
  else
    fail "privileged container could NOT attach a loop device — live-build ISO assembly will fail"
  fi
  if [[ -e /dev/loop-control ]]; then
    info "/dev/loop-control also visible in this namespace"
  else
    info "/dev/loop-control not visible here, but that is this shell's namespace, not the build's"
  fi
else
  warn "docker daemon not reachable — probing the host namespace directly instead"
  probe_rc=0
  probe_loop_on_host || probe_rc=$?
  case "$probe_rc" in
    0) pass "host can attach a loop device" ;;
    2) warn "cannot probe as non-root; re-run with sudo for a complete check" ;;
    *) fail "host cannot attach a loop device — live-build ISO assembly will fail" ;;
  esac
fi

if mountpoint -q /proc 2>/dev/null; then
  info "mount(2) usable"
fi

# --------------------------------------------------------------------------- ZFS on host

section "ZFS on the build host (for building the golden pool natively)"
if have zpool && have zfs; then
  pass "zpool and zfs binaries present"
else
  fail "zpool/zfs not found — the golden pool is built natively on this host"
fi

if grep -qw zfs /proc/modules 2>/dev/null; then
  pass "zfs kernel module loaded"
else
  warn "zfs module not loaded; run: modprobe zfs"
fi

# Binaries and a loaded module are not enough — the build actually runs `zpool create`.
# That needs root plus a usable /dev/zfs. Checking this now avoids discovering it mid-build.
if [[ "$(id -u)" -eq 0 ]]; then
  if zpool list >/dev/null 2>&1; then
    pass "zpool is usable as root (golden pool can be created)"
  else
    fail "zpool is not usable as root — is /dev/zfs present? (build would fail at zpool create)"
  fi
else
  warn "cannot verify zpool is usable without root; re-run with sudo for a complete check"
fi

# --------------------------------------------------------------------------- capacity

section "Capacity"
avail_gb="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
if [[ -n "${avail_gb:-}" ]]; then
  if (( avail_gb >= 40 )); then
    pass "${avail_gb}G free on / (>= 40G recommended for image + golden stream)"
  else
    warn "only ${avail_gb}G free on / — image build plus golden stream may not fit"
  fi
else
  warn "could not determine free space on /"
fi

mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || true)"
[[ -n "${mem_gb:-}" ]] && info "${mem_gb}G RAM"

# --------------------------------------------------------------------------- host tools

section "Tooling"
if have debootstrap; then
  info "debootstrap present on host (not required; mmdebstrap runs in the container)"
else
  info "debootstrap absent on host (fine — mmdebstrap runs in the container)"
fi
if have sgdisk; then
  pass "sgdisk present (used by the stamping script, not by the build)"
else
  warn "sgdisk absent on host (only needed on the target/live env)"
fi

# --------------------------------------------------------------------------- report

section "Summary"
printf '%s\n' "${RESULTS[@]}" >&2
printf '\n%d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN" >&2

if (( FAIL > 0 )); then
  printf '\nResult: BLOCKED — fix the FAIL lines before building.\n' >&2
  exit 1
fi
printf '\nResult: OK — the host can build the golden image and the live medium.\n' >&2
