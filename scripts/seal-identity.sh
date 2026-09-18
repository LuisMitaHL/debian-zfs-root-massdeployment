#!/usr/bin/env bash
# seal-identity.sh — regenerate per-machine identity on FIRST BOOT of a stamped machine.
#
# Why this exists: the golden image is stamped onto many machines. Anything identity-shaped
# that is cloned produces duplicates — and duplicate SSH host keys silently defeat host
# verification for the whole fleet. See DESIGN.md §11.
#
# Installed as a one-shot systemd unit (systemd/zfs-stamp-seal.service) and made idempotent
# with a marker file, so it is safe to leave enabled.
#
# STATUS: first draft, never executed. Validate on a scratch VM.

set -Eeuo pipefail

MARKER="/var/lib/zfs-stamp/sealed"
[[ -e "$MARKER" ]] && exit 0

log() { printf '[seal-identity] %s\n' "$*"; }

# --------------------------------------------------------------------- machine-id
# machine-id(5) explicitly endorses shipping an empty /etc/machine-id and generating a new
# one on first boot.
log "regenerating /etc/machine-id"
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
systemd-machine-id-setup
if [[ -d /var/lib/dbus ]]; then
  ln -sf /etc/machine-id /var/lib/dbus/machine-id
fi

# --------------------------------------------------------------------- SSH host keys
log "regenerating OpenSSH host keys"
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A

# --------------------------------------------------------------------- dropbear keys
# Two *separate* key sets: the normal dropbear server, and the initramfs one. Missing the
# initramfs set is the quiet fleet-wide impersonation bug — it is generated at package
# install time, so it travels in the golden image unless it is removed here.
if [[ -d /etc/dropbear ]]; then
  log "regenerating dropbear (runtime) host keys"
  rm -f /etc/dropbear/dropbear_*_host_key
  dpkg-reconfigure -f noninteractive dropbear || true
fi

if [[ -d /etc/dropbear/initramfs ]]; then
  log "regenerating dropbear-initramfs host keys"
  rm -f /etc/dropbear/initramfs/dropbear_*_host_key
  dpkg-reconfigure -f noninteractive dropbear-initramfs || true
fi

# --------------------------------------------------------------------- /etc/hostid
# NOT regenerated here on purpose: the pool was created during stamping using the hostid
# that was written into /etc/hostid at the same time. Regenerating it now would desynchronise
# the machine from the pool label. See scripts/zfs-stamp.sh stage_pool.
if [[ ! -s /etc/hostid ]]; then
  log "no /etc/hostid present — generating one"
  zgenhostid -f
fi

# --------------------------------------------------------------------- initramfs
# Must be rebuilt now: the initramfs contains the LUKS wiring and the dropbear host keys.
log "rebuilding initramfs"
update-initramfs -u -k all

# --------------------------------------------------------------------- done
mkdir -p "$(dirname "$MARKER")"
date -u +'%Y-%m-%dT%H:%M:%SZ' > "$MARKER"
log "identity sealed"
