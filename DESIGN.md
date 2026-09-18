# Debian 13 root-on-ZFS: agreed provisioning design

**Date:** 2026-09-17
**Status:** agreed design, pre-implementation
**Scope:** fast, repeatable provisioning of Debian 13 "trixie" servers with ZFS root, from a
mobile one-operator setup, for two hardware classes: single-SSD mini PCs and multi-disk
servers with custom mirror/raidz topologies.

This document records decisions reached by interview. Supporting primary-source research is in
[`research/`](research/):
[main findings](research/debian13-zfs-provisioning.md) ·
[bootloaders & LUKS](research/bootloader-luks-notes.md) ·
[backports & compatibility](research/trixie-backports-zfs.md) ·
[live environments](research/live-env-notes.md) ·
[boot design](research/boot-design-notes.md).

---

## 1. Why the current process is slow

The OpenZFS HOWTO is a ~9-step interactive procedure, and Debian trixie ships ZFS **only as
DKMS source in `contrib`** — trixie's kernel packages contain no `zfs.ko`. So today every
machine is hand-typed *and* compiles the ZFS kernel module from source.

The measured pain is **operator labour**, not wall-clock or ZFS throughput. The fix is to
delete interactive steps first, and only then to shorten the build.

## 2. Decisions (the design tree)

```
Objective: provision Debian 13 root-on-ZFS fast, mobile, one operator
│  Root cause of slowness: manual labour; no persistent caches on site
│
├── DELIVERY
│   ├── Install medium ....... custom Debian live-build USB image (iso-hybrid, contrib enabled)
│   ├── Golden root .......... built once (mmdebstrap), stamped via zfs send/recv
│   └── Build host ........... Debian container on the Arch box; ZFS native on host
│
├── ZFS
│   ├── Source ............... trixie-backports 2.4.4 (contrib, DKMS-only)
│   ├── Compat ............... no pinned profile; installer ZFS must not exceed target
│   └── Accepted cost ........ stock-trixie media can never import these pools
│
├── BOOT
│   ├── Firmware ............. UEFI first-class + legacy BIOS
│   ├── Bootloader ........... GRUB everywhere (no bpool, no ZFSBootMenu)
│   ├── /boot ................ ext4; mdadm RAID1 multi-disk, plain on 1-SSD
│   ├── ESP .................. duplicated per disk + efibootmgr entry each
│   └── Secure Boot .......... OFF now; later = signed Debian GRUB + DKMS signing/MOK
│
├── ENCRYPTION
│   ├── LUKS2 under ZFS, per disk
│   ├── Unlock ............... dropbear-initramfs, human SSH + cryptroot-unlock
│   ├── Swap ................. LUKS2 ephemeral key (mini PC only)
│   └── Future ............... Clevis-TPM2 / Tang keyslots (additive, no re-encrypt)
│
├── MEMORY
│   ├── Mini PC .............. swap partition outside pool + zswap
│   ├── Multi-disk server .... zram, no disk swap
│   └── Hibernation .......... disabled everywhere, unconditionally
│
├── FLEET
│   ├── One golden dataset; per-host profile = topology/boot/crypto/variant
│   ├── Identity sealed ....... machine-id, SSH host keys, dropbear initramfs keys, hostid
│   └── Updates .............. unattended-upgrades in place; re-stamp only at Debian 14
│
└── KERNEL ................... trixie stock 6.12
```

Deliberately **rejected**: `debian-installer` preseed for ZFS root (no `partman-zfs` in trixie,
no `zfs` preseed method — it cannot be done); ZFS native encryption (found buggy in testing);
`bpool`; ZFSBootMenu; hibernation; PXE/netboot (ISO-only by decision — one medium to build,
test and carry).

## 3. Hardware classes

| | mini PC | server |
|---|---|---|
| Disks | exactly 1 SSD | N disks, custom mirror/raidz |
| Firmware | UEFI, some legacy BIOS | UEFI, some legacy BIOS |
| Distinct layout | yes — extra swap partition | no swap partition (zram) |

Everything else is shared. The golden root dataset is **identical** across both classes; only
the per-host profile differs.

## 4. Disk layout

### 4.1 Mini PC (single SSD)

| Part | Size | Type | Contents |
|---|---|---|---|
| `p1` | 1 G | `EF00` | ESP — FAT32, GRUB EFI binary |
| `p2` | 1 M | `EF02` | BIOS Boot Partition — only on BIOS units |
| `p3` | 2 G | `8300` | ext4 `/boot` (kernel + initramfs) |
| `p4` | 4 G | `8309` | swap — LUKS2, **ephemeral random key** |
| `p5` | rest | `BF00` | ZFS — LUKS2 container → single-vdev `rpool` |

### 4.2 Server (N disks)

Identical partitioning on **every** disk:

| Part | Size | Type | Contents |
|---|---|---|---|
| `p1` | 1 G | `EF00` | ESP — FAT32; duplicated per disk, one EFI boot entry each |
| `p2` | 1 M | `EF02` | BIOS Boot Partition — only on BIOS units |
| `p3` | 2 G | `FD00` | mdadm RAID1 member → ext4 `/boot` |
| `p4` | rest | `BF00` | ZFS — LUKS2 container → one zpool vdev member per disk |

Notes:

- **Device addressing must use `/dev/disk/by-id/*`.** Never `sdX`. This is a determinism
  requirement, not a preference.
- Firmware cannot assemble mdadm, so the **ESP is duplicated per disk** rather than raided.
  Each disk gets its own `efibootmgr` entry so any single disk can boot alone.
- BIOS Boot Partition ≥ 1 MiB (GRUB requires ≥ 31 KiB; the OpenZFS guide uses 1000 K).
- ZFS redundancy sits **above** LUKS: one LUKS2 container per disk, `zpool` built on
  `/dev/mapper/*`. This is the documented ordering for root-on-ZFS with LUKS; LUKS-over-ZFS
  is not a supported root layout.

## 5. Boot

**Loader: GRUB, on both UEFI and legacy BIOS.** GRUB is Debian-native and signed by Debian,
so it is the least custom option and the one that keeps the future Secure Boot path open.

No bootloader ever reads ZFS. `/boot` (real kernel + initramfs) is a plain ext4 partition;
the initramfs imports the pool. This is what removes `bpool` entirely.

**BIOS+GPT:** requires the `EF02` BIOS Boot Partition; `grub-install` targets the **disk**, not
a partition. GRUB will not work on 4Kn disks under legacy BIOS — check BIOS-era hardware.

**Why not ZFSBootMenu:** its BIOS path needs a separate ext4 `/boot` anyway (syslinux cannot
read ZFS), so the ext4 cost is paid either way; its benefit is boot-environment rollback, which
we do not need; and it ships no Debian package — it would be a self-signed prebuilt EFI binary
built against a specific OpenZFS version, which is exactly the fragility to avoid given the
Secure Boot goal.

**ESPs cannot be mdadm arrays** as far as firmware is concerned. Duplicate them.

Windows-free, single-OS machines: no shim/OS-prober complexity required.

### 5.1 `update-grub` is what makes the machine boot

`grub-install` only lays down the bootloader and its module tree. It does **not** write
`/boot/grub/grub.cfg`. Without an explicit `grub-mkconfig`/`update-grub` the target has a
working core.img, a `/boot/grub/i386-pc/` full of modules, and **no menu** — GRUB falls back to
its own `grub>` prompt and the machine never starts. The first stamped image did exactly this
while the stamping script reported success.

`update-grub` must run **after** the per-machine command line is written, and is verified by the
`stage_verify` stage before the script is allowed to report success.

### 5.2 Serial console (headless machines)

Servers rarely have a monitor, and the LUKS prompt plus the boot log have to be reachable. The
`SERIAL_CONSOLE` profile key (`ttyS0,115200`) sets three layers: the kernel command line
(`console=tty0 console=ttyS0,115200` — `tty0` first so a monitor still shows kernel messages,
while `/dev/console`, and therefore the LUKS askpass prompt, is the serial port), GRUB
(`GRUB_TERMINAL="console serial"`), and a `serial-getty@ttyS0` login prompt on the installed
system.

Without it the LUKS prompt is written to the VGA console only, and the sole way in is
`dropbear` in the initramfs. It is also what makes an automated QEMU boot test possible at all:
there is no way to observe a VGA-only boot without a framebuffer capture.

## 6. ZFS

- **Source:** `trixie-backports` (`zfs-dkms`, `zfsutils-linux`, `zfs-initramfs`, `zfs-zed`
  `2.4.4-1~bpo13+1`, **contrib**). Accepted into stable-backports 2026-09-12.
- **No pinned compatibility profile.** The pool is created with default feature selection, so
  it is **not** permanently ceilinged at 2.4 — a later `zpool upgrade` under a newer OpenZFS
  grows the pool normally.
- This is safe **only because the installer environment is never newer than the target.** The
  live image is built by us from the same trixie-backports source, so live and target both run
  OpenZFS 2.4.4. There is no skew to guard against.
- For reference, the compatibility files (`openzfs-2.3-linux`, `openzfs-2.4-linux`) are
  byte-identical across Debian, backports, Ubuntu and upstream — which is why a profile pin
  works when one is actually needed.

> **Invariant — enforce at build time.** The OpenZFS version in the installer environment must
> never exceed the target's. A pool created by a newer OpenZFS enables feature flags the target
> cannot import, and `zpool upgrade` cannot undo it — four of the 2.4-only features are not
> read-only compatible, so there is no `-o readonly=on` fallback either. If the live
> environment ever moves ahead of the fleet's backports version, pin
> `-o compatibility=<matching profile>` for the duration of pool creation.

**Pool creation (server example):**

```sh
zpool create -f \
  -o ashift=12 \
  -O compression=zstd \
  -O acltype=posixacl \
  -O xattr=sa \
  -O dnodesize=auto \
  -O normalization=formD \
  -O relatime=on \
  -O canmount=off \
  -O mountpoint=none \
  rpool mirror /dev/mapper/zfs0 /dev/mapper/zfs1
# ... raidz1|raidz2|raidz3 with the profile's disk list instead of mirror
```

**No `-R` / `altroot`.** An earlier revision created the pool with `-R /mnt`. `altroot` is a
**persistent pool property**, not a per-import one, so it survived reboots and had to be cleared
before the target could boot; clearing it proved unreliable. Instead the pool is created with
`mountpoint=none canmount=off`, the golden root is received with
`zfs recv -u -o canmount=off -o mountpoint=none`, and mountpoints are set explicitly: `$MNT`
while staging, then `mountpoint=/` + `canmount=noauto` at the end.

The root dataset's `mountpoint` property **must** end up as `/`. The initramfs mounts bootfs
with `mount -o zfsutil`, and `mount.zfs` refuses when the requested target does not match the
dataset's own `mountpoint` — the failure is
`cannot be mounted at '/root//mnt/inspect' due to canonicalization error`, followed by an
`(initramfs)` shell. `stage_verify` checks this.

**Datasets** (identical on both classes):

```
rpool                       canmount=off
rpool/ROOT                  canmount=off
rpool/ROOT/debian           the golden root filesystem
rpool/home                  separate, preserved across re-stamps
```

**Consequences to live with:**

- **A stock trixie ISO can never import these pools — not even read-only.** Four of the six
  2.4-only features are not read-only compatible, so there is no `-o readonly=on` fallback.
  *Every* install and recovery medium must carry backports ZFS ≥ 2.4.
- **`zpool upgrade` is one-way.** It only ever enables more features, and nothing can disable a
  feature once active. Running it raises the minimum OpenZFS version that every future medium
  must carry — recovery media included. Treat it as a fleet-wide change, never a routine
  command.
- The module is **DKMS-only**. Debian ships no prebuilt `zfs.ko`, unlike Ubuntu. DKMS builds
  against the installed kernel and requires the matching `linux-headers-*`.

## 7. Encryption

- **LUKS2, under ZFS, one container per disk.** Chosen over LUKS1 for 32 keyslots vs 8, native
  tokens, and because `systemd-cryptenroll` TPM2 requires LUKS2.
- **Unlock now:** `dropbear-initramfs` — a human SSHes to the machine while it is in the
  initramfs and runs `cryptroot-unlock`.
- **Unlock later:** `clevis luks bind` adds a TPM2 or Tang keyslot **without re-encrypting**.
  `clevis-initramfs` does hook `initramfs-tools` on trixie, so this is a keyslot migration, not
  a reinstall. Plan for a fallback keyslot (Shamir) so a Tang outage cannot brick the fleet.

**Accepted operational cost:** dropbear is remote-**interactive**, not automatic. **Every**
reboot — including an unattended reboot after a power event — stops in the initramfs until a
human connects. With no OOB management, a power blip on a remote mini PC is an outage until
someone SSHes in. This is accepted for now and is the primary driver for moving to Clevis-TPM2.

**Requirements:**

- **`CRYPTSETUP=y` in `/etc/cryptsetup-initramfs/conf-hook` — non-negotiable.** Debian's
  `cryptsetup-initramfs` only pulls itself into the initramfs when it can identify an
  encrypted **root device**. Here the root is a *dataset*, so that detection never fires and
  the initramfs ships without cryptsetup — a stamped machine then cannot unlock its containers
  and **does not boot**. Measured in the VM test: without this, zero cryptsetup and zero
  dropbear entries in the initramfs; with it, 6 and 7 plus the `cryptroot` script.
  `scripts/zfs-stamp.sh` sets it whenever `CRYPT=yes`.
- Each machine needs a **known address** in the initramfs. Use DHCP reservations, or a static
  `ip=` kernel parameter. Otherwise you will not know where to SSH after a power event.
- **`systemd-cryptsetup` must be installed explicitly.** It is only a `Recommends` of `systemd`,
  and the golden image is built with `mmdebstrap --variant=important`, which does not install
  Recommends. That matters more than it looks: Debian **masks** the legacy
  `cryptdisks.service` / `cryptdisks-early.service` (both are symlinks to `/dev/null`), so with
  no `systemd-cryptsetup-generator` **`/etc/crypttab` is completely inert at boot**. Every entry
  the initramfs does not itself handle is silently ignored — including the mini-PC ephemeral
  swap, whose absence costs a ~90 s `dev-mapper-swap.device` timeout on every single boot
  (measured: login prompt at t=112 s without it, t=24 s with it). `stage_verify` fails the run if
  it is missing.
- The `crypttab` source-device field uses **`UUID=<luks-uuid>`**, not a device path: device names
  swap across reboots (`crypttab(5)`: *"Instead of giving the source device explicitly, the UUID
  … is supported as well"*).
- The NIC driver must be present in `/etc/initramfs-tools/modules`.
- `/boot` is **unencrypted** (LUKS sits below the pool). The initramfs must therefore contain
  no secrets.
- LUKS at the block layer is transparent to `zfs send`/`recv`, so encryption does not hinder
  the golden-image pipeline.
- `/boot` on mdadm needs the array anchored by UUID in `/etc/mdadm/mdadm.conf` so the initramfs
  can assemble it; `scripts/zfs-stamp.sh` generates it.

## 8. Memory and swap

| | mini PC | server |
|---|---|---|
| Disk swap | 4 G partition, **LUKS2, ephemeral key** | none |
| Compressed RAM | `zswap` on top of the swap partition | `zram` |
| Hibernation | disabled | disabled |

**Mini PC swap is outside the pool deliberately.** Swap on a ZFS zvol risks memory-pressure
deadlock. It is encrypted with an **ephemeral random key** (`/dev/urandom` keyfile, regenerated
each boot) so that memory pages containing keys and file contents never land on an unencrypted
device — with **no extra passphrase** and no interaction with the dropbear prompt.

**Servers use `zram` only** — compressed RAM, no disk swap, so no swap device exists to leak to.

**Two traps in `systemd-zram-generator`, both measured:**

1. **`zram-size` is an expression in MiB, not a percentage.** It takes a function of `MemTotal`:
   `ram / 2`, `min(ram / 2, 4096)`, `ram / 10`. `ZRAM_SIZE="50%"` makes the generator exit with
   `Error: zram-size zram0` and create **no device at all** — which on a server (`SWAP=none`,
   `ZRAM=yes`) means **no swap whatsoever**, not half of RAM.
2. **The vendor default enables zram whether you ask or not.** The package ships
   `/usr/lib/systemd/zram-generator.conf` containing a bare `[zram0]` section. An `/etc` config
   overrides it wholesale, so a mini PC that only writes a config when `ZRAM=yes` silently gets
   zram **on top of** its ephemeral disk swap. `zfs-stamp.sh` therefore always writes
   `/etc/systemd/zram-generator.conf`: with `[zram0]` for servers, and without it for mini PCs
   (the documented way to disable the device). Verified: no `/etc` file → `dev-zram0.swap` is
   generated; comment-only `/etc` file → nothing is generated.

Emit `console=ttyS0` (see §5.2) on headless machines, or the swap/zram failures above are
invisible until someone attaches a monitor.

### 8.1 No-hibernation provisions (mandatory)

These machines are servers and must **never** hibernate or resume, under any circumstance.

1. **Kernel command line: `nohibernate`** — disables hibernation and resume at the kernel
   level ([kernel-parameters](https://docs.kernel.org/admin-guide/kernel-parameters.html)).
2. **`/etc/systemd/sleep.conf.d/10-no-hibernate.conf`:**
   ```ini
   [Sleep]
   AllowHibernation=no
   AllowHybridSleep=no
   AllowSuspendThenHibernate=no
   ```
   `AllowHibernation=no` already implies the other two; they are stated explicitly for
   auditability ([systemd-sleep.conf](https://www.freedesktop.org/software/systemd/man/latest/systemd-sleep.conf.html)).
3. **Mask the units:**
   ```sh
   systemctl mask hibernate.target hybrid-sleep.target suspend-then-hibernate.target \
                  systemd-hibernate.service systemd-hybrid-sleep.service \
                  systemd-suspend-then-hibernate.service
   ```
4. **No `resume=` on any kernel command line**, no resume device configured; the initramfs
   resume hook is a no-op.
5. **Structural backstop:** mini-PC swap uses an ephemeral per-boot key and servers have no
   disk swap at all — so no durable suspend image can exist even if something tries.
6. **Recommended for headless servers:** also mask `sleep.target` and `suspend.target`, so a
   stray `systemctl suspend` cannot take a machine off the network.

## 9. Golden image build

**Build host:** the operator's Arch Linux box (Arch rolling, kernel 6.18-lts, ZFS already
loaded). Debian-only tooling runs in a container.

Pipeline:

1. On the Arch host, create a build dataset/pool and mount it.
2. In a **Debian trixie container** (`docker` is available; `systemd-nspawn` is an
   alternative): run `mmdebstrap` with `contrib` and trixie-backports enabled, installing
   `zfs-dkms`, `zfsutils-linux`, `zfs-initramfs`, `zfs-zed`, `linux-image-amd64`,
   `linux-headers-amd64`, `dkms`, `build-essential`, `mdadm`, `cryptsetup-initramfs`,
   `dropbear-initramfs`, `grub-efi-amd64`, `grub-pc-bin`, `unattended-upgrades`.
3. Set `SOURCE_DATE_EPOCH` for reproducibility (`mmdebstrap` is documented as bit-by-bit
   reproducible). `mmdebstrap` is also 2–6× faster than `debootstrap` per its authors.
4. Bake in `/etc/systemd/sleep.conf.d/10-no-hibernate.conf`, the `nohibernate` cmdline
   fragment, and the masked sleep/hibernate units.
5. **Seal identity** (§11).
6. `zfs snapshot` → `zfs send -c` to a file on the carrier USB.

**Live medium:** a second `live-build` run produces the installer environment — a Debian live
image with `--archive-areas "main contrib non-free-firmware"`, `zfsutils-linux` + `zfs-dkms`
built at image-build time, the stamping script, and the golden stream. Output:

- `iso-hybrid` with `--bootloaders "syslinux,grub-efi"` → written to USB.

The medium also runs `sshd`: a per-boot 8-char root password is generated by
`live-ssh-setup.service` and the live user's console login prints every interface
address plus that password, so the operator can `ssh root@<addr>`. Sources live in
[`live/`](live/); nothing about it persists past reboot.

**Carried on one USB:** live environment + stamping script + golden stream + the `/boot`
payload. Nothing is fetched at install time.

**Notes / to verify:**

- `live-build` needs privileged loop/mount access to assemble the ISO. Verify this works in
  the container on the real host — a non-privileged container will fail at image assembly.
- DKMS in the golden image must build against the **target** kernel
  (`dkms build -k 6.12.x`), not the container's. The `linux-headers` package for that exact
  kernel plus a toolchain must be inside the image, so that first-boot DKMS works offline.
- Optional future refinement: `dkms mkbmdeb` at image-build time could ship a prebuilt module
  and skip the first-boot compile entirely — subject to a CDDL/GPL redistribution review.

## 10. Stamping flow

Run from the live environment on the target:

1. Confirm target disks by `/dev/disk/by-id/*`; refuse to proceed on ambiguity.
2. Partition every disk (sgdisk), with alignment.
3. Create mdadm RAID1 for `/boot` (servers); mkfs.ext4.
4. Create and open the LUKS2 containers (zpool members; swap on mini PCs).
5. `zpool create` with `ashift=12` and default feature selection (no compatibility pin).
6. `zfs recv` the golden stream into `rpool`.
7. Mount the received root; populate ext4 `/boot` from the carried kernel+initramfs payload;
   run `update-initramfs -u -k all`.
8. `grub-install` to **every** disk; one `efibootmgr` entry per disk (UEFI) and `EF02` for BIOS.
9. **`update-grub`** — see §5.1. Without this the target has no menu and does not boot.
10. Write the per-host profile values (hostname, address, swap/zram variant, serial console,
    kernel command line).
11. **`stage_verify`: refuse to report success on a target that cannot boot.** Checks that
    `grub.cfg` exists and names `root=ZFS=<pool>/ROOT/debian`, that `nohibernate` and the serial
    console are on the kernel line, that the initramfs contains cryptsetup/cryptroot/dropbear
    plus a dropbear host key, that each `crypttab` entry is keyed by LUKS UUID, that
    `/etc/hostid` is per-machine, that `systemd-cryptsetup` is installed, and that the zram
    configuration matches the class. A green `[ ok ] installed` now implies all of that.
12. Seal identity at first boot (§11), then verify (§12).

> **Why the verification stage exists.** The first stamped image reported
> `[ ok ] installed 'mini-single' onto 1 disk(s)` while GRUB had **no `grub.cfg`** and the
> machine could never have booted. Every check above corresponds to a real failure found by
> booting a stamped image, and each one is cheap.

## 11. Identity sealing

Duplicated identity is the classic golden-image bug: two machines sharing an SSH host key
silently defeat host verification. Scrub before sending the stream:

| Item | Action |
|---|---|
| `/etc/machine-id` | empty it (`machine-id(5)` endorses this); regenerate at first boot |
| SSH host keys | delete `/etc/ssh/ssh_host_*`; regenerate at first boot |
| **dropbear initramfs host keys** | delete `/etc/dropbear/initramfs/dropbear_{rsa,ecdsa,ed25519}_host_key`; regenerate with `dpkg-reconfigure dropbear-initramfs` |
| `/etc/hostid` | delete; regenerate per machine with `zgenhostid` |
| Secrets | none baked in — the carrier USB holds an unencrypted root filesystem |

## 12. Fleet model, updates and lifecycle

- **One golden root dataset.** All per-machine variation is a field in a single profile file.
- **Variation axes** — everything below is a profile parameter, not an image fork: pool
  topology, device list, ESP layout, bootloader targets, swap/zram variant, LUKS on/off,
  hostname and addressing.
- **Updates: in-place `unattended-upgrades`.** Re-stamping is reserved for major upgrades
  (e.g. Debian 14), where machines are rebuilt from a new golden image.
- **Keep 2–3 kernels in `/boot`.** This is the mitigation for the one sharp edge of putting
  `/boot` outside the pool: a `zfs rollback` reverts `/lib/modules` but not `/boot`, so at
  least one retained kernel must still pair with the rolled-back module tree. Run
  `update-initramfs` after any rollback.
- **Snapshot `rpool` before significant changes**, since boot-menu rollback is not available.
- **Monitor mdadm.** A silently degraded RAID1 defeats its own purpose; alert on it.
- **Watch `/boot` fill.** It is a fixed-size ext4 partition; kernel accumulation breaks `apt`.

## 13. Secure Boot and TPM roadmap

Secure Boot is **OFF** now, deliberately. The future path is additive:

1. Bootloader work: none. GRUB is Debian-signed; shim + `grub-efi-amd64-signed` work as-is.
2. The only custom binary is `zfs.ko`. Under lockdown it must be signed and its key enrolled
   (MOK, or custom firmware keys). Configure DKMS signing at build time; enrollment is
   per-machine and interactive, which is exactly why it waits.
   **Verified during the VM smoke test:** trixie's `dkms` 3.2.2 already signs modules
   automatically — it generated a self-signed key pair at `/var/lib/dkms/mok.{key,pub}` and
   signed `zfs.ko`/`spl.ko` at build time. So the remaining work is not signing but
   **enrollment**: `mokutil --import /var/lib/dkms/mok.pub`, then one interactive confirmation
   at the next reboot, per machine. That interactive step is the whole reason this is deferred.
3. TPM unlock: `clevis luks bind` adds a TPM2 keyslot to the existing LUKS2 volumes, with no
   re-encryption. Consider binding to Secure Boot state (PCR 7).

## 14. Verification / acceptance gate

Do not trust the pipeline until a freshly stamped machine passes all of this:

- Boots on UEFI **and**, where applicable, legacy BIOS.
- Each disk boots **alone** (servers): remove all but one disk and boot.
- `mdadm --detail /dev/md0` — clean, expected RAID1, no failed members.
- `zpool status` — ONLINE, correct topology; `zpool get compatibility` → `off` (no permanent
  ceiling).
- `uname -r` matches the module tree in `/lib/modules`; `modinfo zfs` reports 2.4.x.
- `lsblk` shows the intended partition scheme; all pools on `/dev/mapper/*`.
- **`systemctl is-active dev-mapper-swap.swap`** on a mini PC (ephemeral swap up), and
  **`swapon --show` shows only `/dev/zram0`** on a server. `systemd-zram-generator` must not be
  erroring — check `journalctl -b | grep -i zram`.
- dropbear unlock reachable at the machine's known address; `cryptroot-unlock` succeeds.
- **No hibernation:** `cat /sys/power/disk` / `state` behaviour consistent with `nohibernate`;
  `systemctl status hibernate.target` masked; `AllowHibernation=no` present.
- **Identity is unique:** two machines stamped from the same image have different
  `/etc/machine-id`, different SSH host keys, different dropbear initramfs host keys, different
  `/etc/hostid`.
- Reboot twice; confirm deterministic behaviour and no surprise prompts.
- Server: simulate a disk failure (`zpool offline` / mdadm fail) and confirm the machine still
  boots from the remaining disk.

## 15. Open items and risks

| Risk / open item | Impact | Mitigation |
|---|---|---|
| `live-build` needs privileged loop/mount access | build fails | verify on the real host before scripting |
| DKMS cross-kernel build in a container | first-boot build fails | build against the target kernel with matching `linux-headers` inside the image |
| backports 2.4.4 accepted only 2026-09-12 | young package | monitor; older bpo versions remain in the pool if a pin is needed |
| Stock trixie media cannot import the pools | no rescue with a plain ISO | all media carry backports ZFS; `zpool upgrade` treated as a fleet-wide change |
| Installer ZFS newer than target ZFS | un-importable pool, unrecoverable | build the live image from backports so live == target; re-introduce a compat pin if that ever changes |
| dropbear = human at every boot | unattended reboots are outages | accepted; migrate to Clevis-TPM2/Tang |
| `/boot` outside the pool | rollback needs a matching kernel | retain 2–3 kernels; `update-initramfs` after rollback |
| mdadm RAID1 `/boot` | silent degradation | monitoring + alerting, not `/proc/mdstat` |
| zram + ZFS ARC contend for RAM | memory pressure / OOM | size zram against ARC (`zfs_arc_max`) deliberately |
| `systemd-cryptsetup` is only a Recommends of systemd | `/etc/crypttab` inert; ~90 s boot stall; no ephemeral swap | installed explicitly and asserted by `stage_verify` |
| Forgetting `update-grub` | target has no GRUB menu and never boots, while stamping reports success | `stage_verify` refuses to pass without a valid `grub.cfg` |
| Hibernation re-enabled by a stray unit | violates a hard requirement | `nohibernate` + sleep.conf + masked units + no swap image |
| `clevis-initramfs` behaviour with initramfs-tools | future TPM path | confirm in a lab machine before committing to it |

## 16. Sources

All primary-source citations are in the five research documents under [`research/`](research/).
Key upstream references:

- OpenZFS Debian Trixie Root on ZFS — <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>
- Debian backports archive — <https://backports.debian.org/uploads/trixie-backports/>
- `zpool-features(7)`, `zpool-upgrade(8)`, `zpoolprops(7)`, `zfs-send(8)`, `zfs-receive(8)`
- Debian Live Manual / `live-build(1)`, `lb_config(1)`
- GRUB manual; systemd `systemd-sleep.conf(5)`, `systemd-boot(7)`
- `crypttab(5)`, `cryptsetup-initramfs`, `clevis-luks`, `dropbear-initramfs`
- Linux `kernel-parameters.txt` (`nohibernate`)
