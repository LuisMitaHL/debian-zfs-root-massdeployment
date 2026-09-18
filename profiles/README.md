# Per-host profiles

A profile describes **one machine class or one machine**: which disks, which pool topology,
which firmware, whether it is encrypted. Everything else comes from the golden image.

## Format

Profiles are **shell fragments sourced by `scripts/zfs-stamp.sh`**. This is deliberate: the
live installer environment is minimal, and sourcing gives us real arrays for disk lists with
**zero parser dependencies** (`yq`, `jq`, Python). There is no YAML parser to install and
nothing to break offline.

> **Trust note:** because a profile is sourced, it executes as shell. Profiles must come from
> the operator's own carrier USB and must never be fetched from an untrusted source.

## Schema

### Required

| Key | Meaning | Values |
|---|---|---|
| `PROFILE_NAME` | Human label, used in logs and the confirmation prompt | string |
| `CLASS` | Hardware class | `mini` \| `server` |
| `HOSTNAME` | Target hostname | string |
| `DISKS` | Bash array of whole-disk paths | **must be `/dev/disk/by-id/*`** |
| `TOPOLOGY` | Pool layout | `single` \| `mirror` \| `raidz1` \| `raidz2` \| `raidz3` |
| `BOOT_MODE` | Firmware to support | `uefi` \| `bios` \| `both` |

### Optional (defaults shown)

| Key | Default | Notes |
|---|---|---|
| `POOL` | `rpool` | pool name |
| `ESP_SIZE` | `1G` | per disk |
| `BOOT_SIZE` | `2G` | ext4 `/boot`, mdadm RAID1 on `server` |
| `BIOS_SIZE` | `1M` | `EF02` BIOS Boot Partition |
| `BOOT_DISKS` | all of `DISKS` | disks that receive a bootloader |
| `CRYPT` | `yes` | LUKS2 containers under the pool |
| `SWAP` | `ephemeral` on `mini`, `none` on `server` | `ephemeral` \| `none` |
| `SWAP_SIZE` | `4G` | mini only |
| `ZSWAP` | `yes` on `mini`, `no` on `server` | compressed cache in front of swap |
| `ZRAM` | `no` on `mini`, `yes` on `server` | RAM-only compressed swap |
| `ZRAM_SIZE` | `ram / 2` | **an expression in MiB, not a percentage** — see note below |
| `ADDRESS` | `dhcp` | `dhcp` \| `static` — applied via `systemd-networkd` (`/etc/systemd/network/10-wired.network`) |
| `SERIAL_CONSOLE` | empty | e.g. `ttyS0,115200`; enables GRUB + kernel + getty on serial |
| `IPV4`, `CIDR`, `GATEWAY`, `DNS` | empty | required when `ADDRESS=static` |
| `GOLDEN_STREAM` | `/media/carrier/rpool.stream.zst` | path to the `zfs send` payload on the carrier |
| `BOOT_PAYLOAD` | `/media/carrier/boot.tar.zst` | kernel+initramfs payload for ext4 `/boot` |
| `DROPBEAR_AUTHORIZED_KEYS` | empty | **required for remote unlock** — pubkey file the initramfs will accept |
| `USERNAME` | empty (root-only) | login user to create with sudo; empty = none |
| `USER_PASSWORD_HASH` | empty (locked) | crypt hash (`openssl passwd -6`) — never plaintext |
| `USER_AUTHORIZED_KEYS` | empty | path on carrier to pubkey file → `~/.ssh/authorized_keys` |
| `USER_SHELL` | `/bin/bash` | login shell (absolute path) |
| `LUKS_KEYFILE` | empty | non-interactive `luksFormat`/`open`; automation only, never leave it on the carrier |

### `ZRAM_SIZE` is an expression, not a percentage

`systemd-zram-generator` evaluates `zram-size` as a function of `MemTotal` in MiB:
`ram / 2`, `min(ram / 2, 4096)`, `ram / 10`.

`ZRAM_SIZE="50%"` does **not** mean half of RAM. The generator exits with
`Error: zram-size zram0` and creates **no zram device at all** — which on a server
(`SWAP=none`, `ZRAM=yes`) leaves the machine with **no swap whatsoever**.
`zfs-stamp.sh`'s verification stage rejects a percentage for this reason.

### Login user

Empty `USERNAME` means root-only, as before. When set, the stamp creates the user
with `sudo` membership, so the `sudo` package must be in the golden image (it is —
see `build/golden-packages.list`; a golden rebuild is required after adding it).

At least one of password hash / SSH key is required, or the account could never
log in. The hash is pre-computed — generate it with:

```sh
openssl passwd -6
```

and paste the `$6$...` string. Never put a plaintext password in a profile: the
profile lives on the carrier USB. Single-quote the hash — it contains `$`
characters that double quotes would expand when the profile is sourced.

### `SERIAL_CONSOLE` (headless machines)
Servers rarely have a monitor attached, and the LUKS passphrase prompt and the boot log need to
be reachable. `SERIAL_CONSOLE="ttyS0,115200"` sets all three layers:

1. the kernel command line (`console=tty0 console=ttyS0,115200` — `tty0` first so a monitor, if
   present, still shows kernel messages, while `/dev/console` and therefore the LUKS prompt is
   the serial port);
2. GRUB (`GRUB_TERMINAL="console serial"`), so the menu and the GRUB shell are usable remotely;
3. a `serial-getty@ttyS0.service` login prompt on the installed system.

Without it the prompt is written to the VGA console only, and the *only* way in is
`dropbear` in the initramfs. Note that VGA-only also makes automated boot testing blind: there
is no way to observe the boot without a framebuffer capture.

## Rules the script enforces

1. **`DISKS` must use `/dev/disk/by-id/`.** Anything else is rejected — `/dev/sdX` names are
   not stable across reboots and are the single most common cause of "it installed to the
   wrong disk".
2. `TOPOLOGY=single` requires exactly one disk; `mirror`/`raidz*` require at least the minimum
   device count for that level.
3. `CLASS=mini` requires exactly one disk.
4. `CLASS=server` with `TOPOLOGY=single` is rejected (that is a mini PC with extra steps).
5. Disk size uniformity is checked; mismatched sizes are a warning, not an error.

## Examples

- [`mini-single.conf`](mini-single.conf) — single-SSD mini PC, LUKS everywhere, ephemeral
  encrypted swap + zswap.
- [`server-mirror.conf`](server-mirror.conf) — two-disk mirror, mdadm RAID1 `/boot`, zram.
- [`server-raidz2.conf`](server-raidz2.conf) — six-disk raidz2.
