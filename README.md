# debian-zfs-root

Fast, repeatable provisioning of **Debian 13 "trixie" servers with ZFS root**, from a mobile
one-operator setup, for single-SSD mini PCs and multi-disk servers.

The agreed design is in **[DESIGN.md](DESIGN.md)**. The primary-source research behind it is in
[`research/`](research/).

> **Status: the pipeline works end to end.** The ISO builds and boots (UEFI and BIOS), the
> installer stamps a real disk in QEMU, and the stamped machine boots on its own — GRUB → kernel
> → LUKS prompt → pool import → login prompt. See
> [What has actually been proven](#what-has-actually-been-proven). What is *not* done is listed
> in [`remaining.md`](remaining.md).

## How it works

```
   Arch build host                         carrier USB                      target machine
   ───────────────                         ───────────                      ──────────────
   build-golden.sh ──► rpool.stream.zst ─┐
                       boot.tar.zst      │
                                         ├──► live env + stamp script ──► zfs-stamp.sh
   build-live.sh ───► installer.iso ─────┘                                  ├─ partition
                                                                           ├─ mdadm /boot
                                                                           ├─ LUKS2
                                                                           ├─ zpool create
                                                                           ├─ zfs recv
                                                                           └─ grub on every disk
                                                                                  │
                                                                            first boot: seal-identity.sh
```

One golden root dataset, stamped onto any number of machines. Per-machine differences are
fields in a **profile file**, never a fork of the image.

## Layout

| Path | What it is |
|---|---|
| [`DESIGN.md`](DESIGN.md) | the agreed design — read this first |
| [`profiles/`](profiles/) | per-host profiles + the schema |
| [`scripts/zfs-stamp.sh`](scripts/zfs-stamp.sh) | stamps the golden image onto a target (dry-run by default) |
| [`scripts/seal-identity.sh`](scripts/seal-identity.sh) | regenerates machine-id, SSH keys, dropbear keys on first boot |
| [`systemd/zfs-stamp-seal.service`](systemd/zfs-stamp-seal.service) | one-shot unit that runs the above |
| [`build/verify-host.sh`](build/verify-host.sh) | checks the build host can actually build |
| [`build/build-golden.sh`](build/build-golden.sh) | builds the golden ZFS dataset and the `/boot` payload |
| [`build/golden-packages.list`](build/golden-packages.list) | base packages baked into the image |
| [`build/golden-customize.sh`](build/golden-customize.sh) | mmdebstrap hook: backports ZFS, no-hibernation, sealing unit |
| [`build/build-live.sh`](build/build-live.sh) | builds the live installer medium (USB ISO, with sshd + per-boot root password) |
| [`tests/smoke-stamp.sh`](tests/smoke-stamp.sh) | end-to-end test of the whole pipeline inside a throwaway VM |
| [`tests/installer-qemu.sh`](tests/installer-qemu.sh) | drives the real installer ISO in QEMU over serial and stamps a disk |
| [`tests/boot-stamped.sh`](tests/boot-stamped.sh) | boots a stamped image in QEMU and answers the LUKS prompt over serial |
| [`tests/inspect-stamped.sh`](tests/inspect-stamped.sh) | assembles a stamped image (LUKS → pool) and dumps its boot-critical config |
| [`remaining.md`](remaining.md) | handover: what is proven, what is not, and the hard-won gotchas |
| [`research/`](research/) | primary-source research with citations and UNVERIFIED flags |

## Before you build

**Run the host check first.** Two things can only fail at the end of a long pipeline:

```sh
sudo ./build/verify-host.sh
```

It checks, among other things, that:

1. **the docker daemon is reachable** — the sandbox where this was written had the `docker`
   binary but no socket, so this is genuinely unverified;
2. **loop devices can be created** — `live-build` cannot assemble an ISO without
   `/dev/loop-control`. This was also unverified at design time.

Do not proceed until both pass.

## Workflow

### 1. Build the golden image (on the Arch build host)

```sh
sudo ./build/verify-host.sh
sudo ./build/build-golden.sh
```

Produces `out/rpool.stream.zst` and `out/boot.tar.zst`. The build creates a **file-backed ZFS
pool literally named `rpool`** so the dataset paths in the stream match the target exactly.

The build aborts if `zfs.ko` is missing from the image or if `/etc/machine-id` is not empty —
both would produce broken or identity-cloned machines.

### 2. Build the live installer medium

```sh
sudo ./build/build-live.sh
```

Produces `out/debian-zfs-installer.iso` (~998 MiB hybrid, syslinux + grub-efi).

### 3. Prepare the carrier USB

The ISO is static; the golden image is not. Keep them apart so the ISO does not need rebuilding
every time the golden image changes:

```sh
sudo dd if=out/debian-zfs-installer.iso of=/dev/sdX bs=4M status=progress oflag=sync
# then create a second partition on /dev/sdX labelled CARRIER and copy:
#   out/rpool.stream.zst  -> /media/carrier/rpool.stream.zst
#   out/boot.tar.zst      -> /media/carrier/boot.tar.zst
```

Profiles default to exactly those paths.

### 4. Stamp a machine

Copy the profile onto the carrier, boot the target from the USB, then:

```sh
sudo /usr/local/sbin/zfs-stamp.sh --profile /etc/zfs-stamp/profiles/server-mirror.conf
```

**Dry run is the default.** Nothing is written until you add `--apply`. The script refuses to
run unless every disk is a real `/dev/disk/by-id/*` device.

### 5. Verify

Run the acceptance gate in [DESIGN.md §14](DESIGN.md). The checks that actually catch
golden-image bugs are **identity uniqueness** (stamp two machines, diff their machine-id, SSH
host keys and dropbear initramfs keys) and **single-disk boot** (servers must boot with all but
one disk removed).

## Testing in a throwaway VM

Four tests, in increasing order of convincingness. All run in the Incus VM, none touch real
hardware.

| Test | What it does | Roughly |
|---|---|---|
| [`tests/smoke-stamp.sh`](tests/smoke-stamp.sh) | stamps loop-backed "disks" with the real script | ~15 min (DKMS dominates; `SKIP_GOLDEN=1` to skip) |
| [`tests/installer-qemu.sh`](tests/installer-qemu.sh) | boots the real ISO in QEMU/BIOS, logs in over serial, stamps one 16 G disk | ~15 min |
| [`tests/boot-stamped.sh`](tests/boot-stamped.sh) | boots the stamped image in QEMU/BIOS and types the LUKS passphrase over serial | ~1 min |
| [`tests/inspect-stamped.sh`](tests/inspect-stamped.sh) | assembles a stamped image offline and dumps its boot-critical config | ~30 s |

```sh
incus launch images:debian/13 zfstest --vm -c limits.cpu=4 -c limits.memory=8GiB
incus storage volume create default scratch --type=block size=30GiB
incus config device add zfstest scratch disk pool=default source=scratch
# Note: device names are NOT stable across VM reboots (sda/sdb swap). Find the scratch disk
# by size rather than hardcoding it.
incus exec zfstest -- bash -c 'S=$(lsblk -dno NAME,SIZE | awk "\$2==\"30G\"{print \$1}" | head -1);
  mkfs.ext4 -F "/dev/$S" && mkdir -p /mnt/scratch && mount "/dev/$S" /mnt/scratch'
incus file push -r . zfstest/
incus exec zfstest -- bash /root/debian-zfs-root/tests/installer-qemu.sh
incus exec zfstest -- bash /root/debian-zfs-root/tests/boot-stamped.sh
```

`installer-qemu.sh` takes `scripts/zfs-stamp.sh` **from the carrier**, not from the copy baked
into the ISO, so a script change is testable in ~15 minutes rather than after a ~16-minute ISO
rebuild.

To look at a stamped image without booting it:

```sh
incus exec zfstest -- bash /root/debian-zfs-root/tests/inspect-stamped.sh /mnt/scratch/single.img
```

It prints `crypttab`, `fstab`, the `CRYPTSETUP` hook, `grub.cfg`'s default entry, the root
dataset properties and the initramfs's cryptsetup/dropbear counts, then tears everything down
and — importantly — restores the root dataset's `mountpoint=/`, which it has to change in order
to mount the golden root somewhere harmless. **Prefer BIOS for automated tests**: no OVMF, no
`vars.fd`, no NVRAM to accumulate stale boot entries.

Tear down with:

```sh
incus delete -f zfstest && incus storage volume delete default scratch
```

`build-golden.sh --native` runs `mmdebstrap` directly instead of in a container. It is what the
smoke test uses, and it is also the right mode if you ever build on a Debian host.

## What has actually been proven

Everything below was executed in the test VM; the artifacts are the QEMU console logs.

| Proven | Evidence |
|---|---|
| The ISO **builds** — 998 MiB bootable hybrid, ~16 min with a warm cache | `out/build-live.log` |
| The ISO **boots UEFI and BIOS** | serial captures of both |
| The **package cache persists** — 890 MB in `out/lb-cache/` | see [Caching downloads](#caching-downloads) |
| The **installer runs end to end in QEMU/BIOS** and stamps one disk | `installed 'mini-single' onto 1 disk(s)` |
| **The stamped machine boots**: GRUB menu → kernel → `Please unlock disk zfs0` → `cryptsetup: zfs0: set up successfully` → `Debian GNU/Linux 13 mini01 ttyS0` → `login:`, in **27 s** | `tests/boot-stamped.sh` |
| **The booted machine's own journal confirms the plumbing**: `root=ZFS=rpool/ROOT/debian … nohibernate zswap.enabled=1 console=tty0 console=ttyS0,115200`; `zswap: loaded using pool lzo/zsmalloc`; `systemd-makefs: /dev/mapper/swap successfully formatted as swap`; `Activated swap dev-mapper-swap.swap`; **0** dependency failures or timeouts | `journalctl -D <root>/var/log/journal -b` |
| `crypttab` is keyed by **LUKS UUID**, so the boot does not depend on device names | locked container opened by UUID at boot |
| The **ISO carries `/README.txt`** at its root (and `/root/README.txt` in the live session), byte-identical to `build/iso-readme.txt` | `isoinfo -x '/README.TXT;1'` |
| **OpenZFS 2.4.4 compiles via DKMS** against the stock 6.12 kernel | `find … -name 'zfs.ko*'` |
| The initramfs contains **cryptsetup + dropbear** (6 / 7 entries) and a per-machine dropbear host key | `lsinitramfs` |
| `/dev/disk/by-id` behaves; partitions are addressed as `<by-id>-part<N>` | installer log |

## The bugs booting a stamped image found

The project's own test suite reported success four times on machines that could not boot. Booting
one is what exposed all of these:

1. **No `grub.cfg`.** `grub-install` lays down modules but does *not* write a menu; nothing ran
   `update-grub`. The target had `i386-pc/` with 289 modules, a `grubenv`, and no `grub.cfg` —
   GRUB drops to its own prompt. This is why a stamped machine had never booted.
2. **`systemd-cryptsetup` missing.** It is only a `Recommends` of `systemd`, and
   `--variant=important` drops Recommends. Debian **masks** `cryptdisks.service` (it is a symlink
   to `/dev/null`), so `/etc/crypttab` was *completely inert at boot*: the ephemeral swap device
   never appeared and every boot stalled ~90 s on `dev-mapper-swap.device`. Login prompt at
   **t=112 s → t=24 s** once installed.
3. **`zram-size = 50%` is not a valid value.** `systemd-zram-generator` wants an *expression in
   MiB* (`ram / 2`). `50%` makes the generator exit with an error and create **no device** — so a
   server with `SWAP=none, ZRAM=yes` had **no swap at all**.
4. **zram was on even where it was turned off.** The package ships a bare `[zram0]` section in
   `/usr/lib/systemd/zram-generator.conf`; with no `/etc` override the default applies, so mini
   PCs got zram swap on top of their disk swap. The stamp script now always writes
   `/etc/systemd/zram-generator.conf`.
5. **`zpool export` failed on every run.** Three real causes, all fixed and all mount-related:
   `umount` was being used on ZFS *dataset* mountpoints (`umount -l` detaches a dataset without
   telling ZFS, after which `export`, `export -f` and `destroy -f` all refuse with nothing
   mounted, until a reboot); `zfs unmount -a` **skips `canmount=noauto` datasets**, which the
   staging root deliberately is; and leaving the root mounted while `stage_finish` rewrites its
   `mountpoint` to `/` makes `zpool export` try to unmount the live root. A fourth cause remains
   unidentified **in the live environment only** — the equivalent sequence exports cleanly on the
   VM host, and stopping `zfs-zed` (which does run on the medium) did not help. It is non-fatal
   and the target boots; see [`remaining.md`](remaining.md) §5.5.
6. **`zswap.compressor=zstd` did nothing.** Debian builds the crypto algorithm as a module
   (`CONFIG_CRYPTO_ZSTD=m`) and zswap initialises before modules can load, so every boot logged
   `zswap: compressor zstd not available, using default lzo`. The request has been removed; the
   journal now shows `zswap: loaded using pool lzo/zsmalloc` with no complaint.

`zfs-stamp.sh` gained a `stage_verify` stage that refuses to report success unless `grub.cfg` is
valid, the initramfs can unlock the pool, `crypttab` entries are UUID-keyed, `systemd-cryptsetup`
is present and the zram config matches the class. Every check corresponds to one of the failures
above, plus two that only showed up in the logs.

### The earlier bug the VM test existed to find

Debian's `cryptsetup-initramfs` only pulls itself into the initramfs when it can identify an
encrypted **root device**. With ZFS-on-LUKS the root is a *dataset*, so that detection never
fires: the initramfs shipped with **zero** cryptsetup and **zero** dropbear entries, and a
stamped machine would not have booted. `scripts/zfs-stamp.sh` now forces `CRYPTSETUP=y` in
`/etc/cryptsetup-initramfs/conf-hook`. Measured before/after: cryptsetup 0 → 6 entries,
dropbear 0 → 7, plus the `cryptroot` script.

## Caching downloads

**Yes, and you are already paying for it twice if you don't.** live-build caches by default —
`--cache`, `--cache-packages` and `--cache-indices` all default to *true* — storing downloaded
`.deb` files and apt indices under `<build>/cache`. Our first ISO builds threw that away,
because the build runs on the container's own filesystem (it has to: see below) and the
container is `--rm`.

`build-live.sh` now bind-mounts a host directory (`out/lb-cache`, override with `CACHE_DIR=`)
over `/lb/cache`, so the cache survives between runs. This is safe on the host's `nodev`
subvolume precisely because the cache holds only regular files — no device nodes, unlike the
chroot.

Measured after one build:

| Cache component | Size | What it saves |
|---|---|---|
| `packages.chroot` | 518 M | the bulk of the ~1 GB of `.deb`s |
| `bootstrap` | 261 M | the debootstrap stage |
| `packages.bootstrap` | 48 M | bootstrap packages |
| `contents.chroot` | 49 M | the contents index |
| `packages.binary` | 15 M | binary-stage packages |
| **total** | **890 M** | |

To go further, point the build at your existing **apt-cacher-ng** (`laotrared-debian-mirror`)
with `lb config --apt-http-proxy`. That caches across *machines and clean rebuilds*, which the
local cache cannot.

## Still unverified

| Area | Why it still needs a look |
|---|---|
| **Real hardware** | Everything was tested in QEMU. `DESIGN.md` §14 (identity uniqueness across two machines, single-disk boot, mdadm degradation) has never run on a physical machine. |
| UEFI automated test | The stamped image has only been booted on **BIOS**. UEFI booting of the ISO works, but the automated UEFI test drops to the firmware shell because the reused `vars.fd` accumulates NVRAM entries; use a fresh `OVMF_VARS_4M.fd` per run and `-boot order=d`. |
| **`/etc/hostid` vs the pool-label hostid** | `zgenhostid` writes the file; whether it updates the running kernel hostid ZFS reads is unclear. Symptom if it matters: "pool may be in use from other system" → one-off `zpool import -f`. The stamped image did boot, so it is at least not fatal. |
| Server class end to end | Only the mini profile has been stamped and booted. mdadm RAID1 `/boot`, raidz topologies, and the zram path are exercised only by the loop-disk smoke test. |
| `smoke-stamp.sh` status | It was 14/14 **before** `stage_finish` and the crypttab-UUID change landed, and has not been green since — the VM rebooted mid-run twice. Its assertions have been updated for the new `stage_verify` stage and the root-dataset layout, plus new ones for `grub.cfg`, `systemd-cryptsetup` and zram, but it has not been re-run to green. See `remaining.md` §5.1 and §5.2. |
| Cache speedup | The 890 MB cache is populated; the second-build speedup has not been measured. |
| Secure Boot | Off. DKMS already auto-signs `zfs.ko` with `/var/lib/dkms/mok.{key,pub}`; the remaining work is MOK **enrollment**. |

## Decisions worth remembering

- **No `bpool`, no ZFSBootMenu.** GRUB on both UEFI and BIOS; `/boot` is ext4 (mdadm RAID1 on
  servers), so no bootloader ever reads ZFS. This keeps the future Secure Boot path to a signed
  Debian GRUB plus a signed `zfs.ko`.
- **No compatibility pin** on `zpool create`. Safe only because the installer environment is
  built from the same trixie-backports source as the target. If the live environment ever moves
  ahead of the fleet's OpenZFS version, the pin must come back — see DESIGN.md §6.
- **No `altroot` (`-R`).** It is a *persistent* pool property, not a per-import one, so it
  survives reboots and has to be cleared before the target can boot. Mountpoints are set
  explicitly instead.
- **The kernel command line is not optional plumbing.** `nohibernate`, the serial console and
  the zswap parameters all reach the kernel through `/etc/default/grub.d/99-zfs-stamp.cfg`,
  which only takes effect because `update-grub` runs afterwards.
- **`SERIAL_CONSOLE` for headless machines.** It is the only way to see the LUKS prompt and the
  boot log without a monitor — and the only way to test a boot automatically.
- **Hibernation is disabled four ways**: `nohibernate`, `sleep.conf.d`, masked units, and the
  absence of any resumable swap image.
- **dropbear unlock is interactive.** Every unattended reboot needs a human. Migrating to
  Clevis-TPM2/Tang is the planned fix.
