#!/bin/sh
# live-ssh-setup.sh — run once per live boot by live-ssh-setup.service (as root).
#
# Generates an 8-char root password and makes sure sshd accepts it, so the operator
# can drive the installer over SSH instead of (or as well as) the local console.
# The password is printed by /etc/profile.d/zz-live-ssh.sh at the live user's login.

set -eu

PW_FILE="/run/live-ssh/root-pw"
mkdir -p "$(dirname "$PW_FILE")"

# 8 alphanumeric chars from the kernel RNG.
PW=""
while [ "${#PW}" -lt 8 ]; do
  PW="$PW$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8)"
done
PW="$(printf '%.8s' "$PW")"

printf 'root:%s\n' "$PW" | chpasswd
# chpasswd replaces the hash, which normally unlocks the account; be explicit anyway.
passwd -u root > /dev/null 2>&1 || true

printf '%s' "$PW" > "$PW_FILE"
# The live medium is ephemeral; the console banner reads this file as the live user.
chmod 0644 "$PW_FILE"

# sshd is enabled at build time; make sure it is actually up (belt and braces for
# live-boot service ordering).
if command -v systemctl > /dev/null 2>&1; then
  systemctl start ssh.service || true
else
  service ssh start || true
fi
