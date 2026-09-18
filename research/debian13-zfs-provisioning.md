# Fast, repeatable Debian 13 (trixie) root-on-ZFS provisioning

**Research date:** 2026-09-17 (UTC). Package versions, release dates and "current release"
statements are pinned to that date.

**Scope:** How to provision Debian 13 "trixie" machines with ZFS as the root filesystem
faster and more repeatably than the manual OpenZFS procedure, for (a) mini PCs with exactly
one SSD and (b) servers with multiple disks in custom layouts (mirrors, raidzN).

**Method:** primary sources only (OpenZFS docs/manpages, Debian official docs / package
tracker / BTS / Salsa, Ubuntu & Canonical docs and package indices, freedesktop/systemd,
UAPI spec). Every non-obvious claim carries an inline link to the source that owns it.
Anything unconfirmable from a primary source is marked **UNVERIFIED**. No benchmark numbers,
package versions or release dates are invented.

---

## 1. Summary of the recommended approach

The status quo is slow for two reasons, and neither is "ZFS is slow":

1. **The ZFS kernel module is built from source per machine.** Debian trixie ships OpenZFS
   only as **DKMS source in `contrib`** (`zfs-dkms` 2.3.9-0+deb13u1); trixie's kernel
   packages do **not** contain `zfs.ko`
   ([zfs-dkms](https://packages.debian.org/trixie/zfs-dkms),
   [linux-image filelist](https://packages.debian.org/trixie/amd64/linux-image-6.12.107+deb13-amd64/filelist),
   [wiki.debian.org/ZFS](https://wiki.debian.org/ZFS)). Compiling ZFS on every host is the
   long pole.
2. **It is a long interactive procedure.** The OpenZFS HOWTO is ~9 steps of hand-typed
   partitioning, pool creation, chroot configuration, bootloader installation and
   mount-ordering fixes.

The fix is to **build a golden Debian 13 root-on-ZFS image once** and **stamp it onto each
machine with `zfs send | zfs recv`**, fixing per-machine identity at first boot. Per-machine
work becomes a disk write instead of a package build.

For **multi-disk servers**, keep per-machine pool topology under script control
(`zpool create … mirror|raidzN` with the right `ashift`) and `zfs recv` the golden root into
it. For **single-SSD mini PCs**, it is even simpler: one pool, one ESP, no redundancy steps,
identical hardware class → the same stream on every unit.

**Bootloader recommendation:** use **ZFSBootMenu** (single pool, no separate GRUB-compatible
`bpool`, snapshot/boot-environment aware) or **sd-boot with kernels on the ESP/XBOOTLDR**.
Keep GRUB only if you need it, and then keep the HOWTO's `bpool` + `compatibility=grub2`
design. Note ZFSBootMenu has **no Debian package** ([search](https://packages.debian.org/search?keywords=zfsbootmenu&searchon=names&suite=all&section=all)),
so you carry a pinned prebuilt EFI binary or a local build.

**Critical compatibility rule:** whatever creates the pool must pin a trixie-supported
feature set, e.g. `-o compatibility=openzfs-2.3-linux`, because the live distro's OpenZFS may
be newer than trixie's (Ubuntu 26.04 = 2.4.1, trixie = 2.3.9; see §7.1).

---

## 2. Comparison table of provisioning approaches

| Approach | Speed | Repeatability / determinism | Maintenance cost | Multi-disk (mirror/raidz) | 1-SSD mini PC | Key caveat |
|---|---|---|---|---|---|---|
| **Manual OpenZFS HOWTO** (status quo) | Slowest: interactive + DKMS build per machine | Low: human typing, device names, ordering | Low code, high human cost | Manual per disk | Manual | Error-prone bootloader mirroring and bpool import ([guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)) |
| **Scripted `debootstrap` chroot** | Better; still DKMS-compiles ZFS; `debootstrap` is the slower bootstrap | Medium | Medium | Scripted | Scripted | Needs shell logic for partition/zpool |
| **Scripted `mmdebstrap` chroot** | Faster bootstrap (2–6× vs debootstrap per tool docs) | High: "bit-by-bit reproducible" with `$SOURCE_DATE_EPOCH` | Medium | Scripted | Scripted | Still DKMS-builds ZFS unless prebuilt ([README](https://salsa.debian.org/debian/mmdebstrap/-/raw/master/README.md)) |
| **Golden image via `zfs send \| zfs recv`** | Fastest per machine: a stream write, no install/compile | Highest: identical bytes per machine | Highest upfront, lowest per machine | Works with any `zpool create` topology | Excellent | Must scrub identity (`machine-id`, SSH keys, `/etc/hostid`, pool GUID) — §9 |
| **ZFSBootMenu** (bootloader choice) | One-time; prebuilt EFI or `generate-zbm` | High | Low–medium (no Debian package) | Single-pool; mdraid ESP guide | Excellent | Prebuilt EFI built against a specific OpenZFS version ([docs](https://docs.zfsbootmenu.org/en/latest/guides/debian/uefi.html)) |
| **Ubuntu Subiquity autoinstall ZFS** | Fast on Ubuntu hardware | High for Ubuntu | Medium | Guided layout is **single-disk only**; RAIDZ/mirror **not documented** | Yes | Produces **Ubuntu**, not Debian; OpenZFS 2.4.1 skew (§7) |
| **`debian-installer` + preseed** | N/A | N/A | N/A | **Not possible** | **Not possible** | No ZFS-root support in trixie at all (§5) |
| **curtin / cloud-init** | N/A for Debian ZFS root | High for Ubuntu/MAAS | Medium | curtin `zpool`/`zfs` actions are **Experimental** | Yes | curtin targets Ubuntu/MAAS; cloud-init is first-boot config, not partitioning (§6.4) |

> Synthesis table; supporting citations are in the sections below.

---

## 3. Q1 — What the OpenZFS trixie guide actually does, and where the time/risk is

Source: [OpenZFS, *Debian Trixie Root on ZFS*](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html).

Nine steps:

1. **Prepare the install environment** — boot the Debian live GUI ISO, set apt sources,
   optionally install SSH, disable automount, `sudo -i`, install `linux-headers-generic`
   (workaround for [Debian bug #1091428](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1091428)),
   then `debootstrap gdisk zfsutils-linux`.
2. **Disk formatting** — set `DISK=/dev/disk/by-id/...`, wipe MD/ZFS signatures,
   `sgdisk --zap-all`, create BIOS (`EF02`), ESP (`EF00`, +512M), boot pool (`BF01`, +1G)
   and root (`BF00`) partitions; `zpool create` for `bpool`
   (`-o ashift=12 -o autotrim=on -o compatibility=grub2 … -O mountpoint=/boot -R /mnt`) and
   `rpool` (optionally `-O encryption=on -O keyformat=passphrase`, or LUKS).
3. **System installation** — create `rpool/ROOT`, `bpool/BOOT` and child datasets, mount a
   tmpfs at `/run`, `debootstrap trixie /mnt`, copy `/etc/zfs/zpool.cache`.
4. **System configuration** — hostname/hosts, network, apt sources, bind-mount
   `/dev /proc /sys`, `chroot`, install `console-setup locales`, `zfs-initramfs`, NTP, GRUB,
   root password, the `zfs-import-bpool.service` workaround, optional SSH and Dropbear.
5. **GRUB installation** — `grub-probe /boot`, `update-initramfs -c -k all`, set
   `GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/debian"`, `update-grub`, `grub-install`, then run
   `zed -F` to populate `/etc/zfs/zfs-list.cache/*` and `sed` out the `/mnt` prefix.
6. **First boot** — snapshot, exit chroot, unmount, `zpool export -a`, reboot, create a user,
   and **mirror GRUB onto the other disks**.
7. **Optional swap** — zvol swap (`-b $(getconf PAGESIZE)`, `compression=zle`,
   `sync=always`, `primarycache=metadata`) plus `RESUME=none`.
8. **Full software installation** — `apt dist-upgrade`, `tasksel --new-install`.
9. **Final cleanup** — delete install snapshots, disable root password / root SSH, restore
   graphical boot, back up the LUKS header.

### Steps that dominate wall-clock time

- **DKMS compilation of ZFS.** The HOWTO installs `zfs-initramfs` inside the chroot, and in
  trixie the module comes only from `zfs-dkms` (which depends on `dkms` and `libc6-dev`);
  `zfsutils-linux` recommends a **virtual** `zfs-modules` whose only provider is `zfs-dkms`
  ([zfs-dkms](https://packages.debian.org/trixie/zfs-dkms),
  [zfsutils-linux](https://packages.debian.org/trixie/zfsutils-linux)). Compiling SPA/DMU/
  ZVOL/ZPL is the dominant per-machine cost, followed by `apt` download/install and
  `update-initramfs`. The guide notes initramfs images "may be around 85M each" and a
  kernel+initrd "around 100M" ([guide Step 2](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)).
- **`debootstrap`.** The guide uses `debootstrap` and never mentions `mmdebstrap`.
- **Interactive steps 4–6** (locale/tz/keyboard `dpkg-reconfigure`, `passwd`, `tasksel`).

### Most error-prone steps to automate

- **Device naming.** The guide requires `/dev/disk/by-id/*` "because `/dev/sd*` … can cause
  sporadic import failures".
- **Partition offsets/types and the `-partN` suffix.** Getting `-part4` (partition) vs the
  whole disk wrong destroys the bootloader partitions.
- **`bpool` import.** The `zfs-import-bpool.service` workaround exists because `bpool` must be
  imported before `zfs-import-scan/cache`; the guide notes it "may fail" on NVMe and needs
  `-d DISK-part3`.
- **The `zed` mount-generator dance** (`zfs-list.cache` regeneration + `sed`, with retries).
- **Bootloader mirroring**, explicitly deferred to first boot and done by hand
  (`dpkg-reconfigure grub-pc`, or `dd` + `efibootmgr`).
- **Unmount/export ordering** before reboot (three documented "pool busy" fallbacks).
- **Passphrase prompts** make encrypted/LUKS installs non-unattended.

---

## 4. Q2 — Speed comparison: debootstrap vs mmdebstrap vs debian-installer

**There are no official Debian benchmarks comparing all three.** What exists:

- `mmdebstrap`'s README publishes a table (Intel Core i5-5200U, localhost mirror, tmpfs)
  ([README](https://salsa.debian.org/debian/mmdebstrap/-/raw/master/README.md)):

  | variant | mmdebstrap | debootstrap |
  |---|---|---|
  | essential | 9.52 s | n.a. |
  | apt | 10.98 s | n.a. |
  | minbase | 13.54 s | 26.37 s |
  | buildd | 21.31 s | 34.85 s |
  | (default) | 23.01 s | 48.83 s |

  The README calls it "twice as fast", "a chroot with apt in 11 seconds", and "bit-by-bit
  reproducible output" when `$SOURCE_DATE_EPOCH` is set.
- Debian's package description for trixie's `mmdebstrap` (1.5.7-1+deb13u1) says it "is 3-6
  times faster" ([packages.debian.org/trixie/mmdebstrap](https://packages.debian.org/trixie/mmdebstrap)).
  Note the two official sources quote **different** multipliers ("twice" vs "3–6×").

**Caveats / UNVERIFIED:** these are the tool author's numbers on 2015-era laptop hardware
against a localhost mirror and tmpfs; they are not predictions for your hardware, mirror, or
a ZFS+DKMS workload. There is **no** published first-party benchmark for `debian-installer`
rootfs creation speed, and no published mmdebstrap benchmark that includes building
`zfs-dkms`. Treat all figures as order-of-magnitude only.

For completeness, trixie ships `debootstrap` 1.0.141 and `mmdebstrap` 1.5.7-1+deb13u1
([debootstrap](https://packages.debian.org/trixie/debootstrap),
[mmdebstrap](https://packages.debian.org/trixie/mmdebstrap)). Useful mmdebstrap controls
(from the [trixie manpage](https://manpages.debian.org/trixie/mmdebstrap/mmdebstrap.1.en.html)):

- `--variant`: `extract`, `custom`, `essential`, `apt`, `required`, `minbase`, `buildd`,
  `important`, `debootstrap`, `-`, `standard` (default `debootstrap`). `apt` = Essential +
  apt; `minbase` = Essential + Priority:required.
- `--mode`: `auto`, `sudo`, `root`, `unshare`, `fakeroot`, `fakechroot`, `chrootless`
  (default `auto`). `root`/`sudo` need `CAP_SYS_ADMIN`; `unshare` needs `/etc/subuid` +
  `/etc/subgid` and uidmap; `chrootless` "only very few packages support".

`debian-installer` is not a drop-in alternative anyway: it cannot produce ZFS root on trixie
(§5), so the meaningful comparison is `debootstrap` vs `mmdebstrap` for populating a
pre-created ZFS root dataset.

---

## 5. Q3 — Can the Debian trixie installer produce ZFS root via preseed?

**No. There is no ZFS-root path in the trixie installer.**

- **`partman-zfs` is not in trixie.** A name search returns "Sorry, your search gave no
  results" ([trixie search](https://packages.debian.org/search?keywords=partman-zfs&searchon=names&suite=trixie&section=all));
  `partman-auto-zfs` likewise has no results.
- **Historical correction:** a `partman-zfs` *did* exist, but only for **kFreeBSD**, never
  Linux. `tracker.debian.org/pkg/partman-zfs` records source version **56** with the status
  "package is gone — This package is not part of any Debian distribution"
  ([tracker](https://tracker.debian.org/pkg/partman-zfs)); its `debian/control` declares
  `Package-Type: udeb` with `Architecture: kfreebsd-any`
  ([control](https://salsa.debian.org/installer-team/partman-zfs/-/raw/master/debian/control)).
  It was removed from testing in 2015, and kFreeBSD moved to debian-ports, which is why
  Debian bug [#648109](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=648109) was closed
  as `56+rm`. Its historical templates did offer Striped/Mirror/RAID-Z modes, but that is
  irrelevant to trixie/amd64.
- **No preseed directive exists.** The trixie installer manual documents the complete set of
  `partman-auto/method` values as: "regular", "lvm", and "crypto" — there is no `zfs` value
  ([preseeding appendix B.4.8](https://www.debian.org/releases/trixie/amd64/apbs04.en.html)).
  The partitioning chapter's supported-filesystem list is ext2/3/4, jfs, xfs, reiserfs,
  qnx4, FAT16/32 and (read-only) NTFS — **no ZFS**; guided partitioning offers only classic,
  LVM and encrypted LVM ([installation guide §6.3](https://www.debian.org/releases/trixie/amd64/ch06s03.en.html)).
- **Debian's own package says it outright.** For trixie 2.3.9-0+deb13u1,
  `zfs-linux`'s `debian/README.Debian` states: *"Debian Installer does not support root
  installation because zfs udeb modules are not built in-tree with the linux kernel, and
  zfs-initramfs is included here for people interested to setup ZFS as rootfs manually.
  Since faulty operation on filesystem can lead to major loss of data, please use
  zfs-initramfs with caution."*
  ([README.Debian](https://sources.debian.org/src/zfs-linux/2.3.9-0+deb13u1/debian/README.Debian/))
- The trixie release notes do **not** mention ZFS at all; the installation chapter covers Pure
  Blends, cloud images and container/VM images, and the issues chapter covers dm-crypt and
  `systemd-cryptsetup`, not ZFS
  ([release-notes §3](https://www.debian.org/releases/trixie/release-notes/installing.en.html),
  [§5](https://www.debian.org/releases/trixie/release-notes/issues.en.html)).
- There is **no Debian wiki root-on-ZFS page**: `https://wiki.debian.org/ZFSOnRoot` returns
  404, and the wiki's ZFS page has no root-on-ZFS/installer-root section
  ([wiki.debian.org/ZFS](https://wiki.debian.org/ZFS)).
- The 2017 request to add ZFS to `debian-installer`
  ([bug #861263](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=861263)) is tagged
  **`wontfix`**, with the stated reason "ZFS binaries are not distributable due to the
  licence conflict" — the binary module mixes CDDL and GPLv2, which is why ZFS lives in
  `contrib`, not `main`. No newer primary source reversing this was found, and the continued
  absence of `partman-zfs` for Linux is consistent with it.

**What OpenZFS upstream recommends / does:** the OpenZFS Debian page sends root-on-ZFS users
to the manual HOWTO and documents `zfs-dkms`/`zfsutils-linux` from `contrib` for adding ZFS
to an existing system
([OpenZFS Debian index](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/index.html)).
A blanket "OpenZFS recommends against the distro installer" is an **inference**, not a quote
— **UNVERIFIED** as a verbatim recommendation. The strongest evidence is the Ubuntu guide's
note that "The Ubuntu installer still has ZFS support, but it was almost removed for 22.04
and it no longer installs zsys" ([Ubuntu 22.04 guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html)).

---

## 6. Q4 — State of the art for automated ZFS-root provisioning (2025/2026)

### 6.1 Scripted chroot (automate the HOWTO)

The HOWTO is already a chroot procedure, so automation means making Steps 1–6 idempotent
shell. Lowest risk of diverging from upstream's documented layout; still bootstraps and
DKMS-builds per machine unless you prebuild/cache.

### 6.2 Golden image via `zfs send | zfs recv` (highest leverage)

- `zfs send -R` "will replicate the specified file system, and all descendent file systems,
  up to the named snapshot. When received, all properties, snapshots, descendent file
  systems, and clones are preserved"
  ([zfs-send(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-send.8.html)).
- Upstream literally documents the golden-image pattern: `zfs snapshot pool/vm/base@golden`
  then `zfs clone pool/vm/base@golden pool/vm/guest1` — "Typical uses of clones are virtual
  machine images from a common golden image…"
  ([Snapshots and Clones](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Datasets/Snapshots%20and%20Clones.html)).
- You can receive a full stream as a clone with `zfs receive -o origin=snapshot`: "If the
  stream is a full send stream, this will create the filesystem described by the stream as a
  clone of the specified snapshot" ([zfs-receive(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-receive.8.html)).
- For native encryption, `zfs send -w` sends ciphertext so keys need not be loaded, and "the
  received dataset keeps its encryption, and its key, from the source" (though `keylocation`
  defaults to `prompt`); raw and non-raw receives cannot be mixed
  ([zfs-send(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-send.8.html),
  [Native Encryption](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Encryption.html)).
- ZFSBootMenu can "even bootstrap a system installation via `zfs recv`" and offers runtime
  `[ENTER] duplicate` (implemented as `zfs send | zfs recv`), clone/promote, and rollback
  ([overview](https://docs.zfsbootmenu.org/en/latest/),
  [snapshot management](https://docs.zfsbootmenu.org/en/latest/online/snapshot-management.html)).
- The HOWTO itself lists "copy the entirety of a working system into the new ZFS root" as an
  alternative to `debootstrap` ([guide Step 3.5](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)).

**Trade-off:** fastest and most deterministic per machine; you must scrub identity (§9) and
still create each machine's pool for custom multi-disk layouts.

### 6.3 ZFSBootMenu (bootloader)

ZFSBootMenu is "a bootloader that provides a powerful and flexible discovery, manipulation
and booting of Linux on ZFS"; prebuilt images are "based on Void Linux", it supports "Debian
and its descendants", and boots environments via `kexec`
([overview](https://docs.zfsbootmenu.org/en/latest/)). Upstream source is
[github.com/zbm-dev/zfsbootmenu](https://github.com/zbm-dev/zfsbootmenu);
`zfsbootmenu.org` redirects to the docs site.

**Packaging reality:** there is **no `zfsbootmenu` package in Debian**
([search](https://packages.debian.org/search?keywords=zfsbootmenu&searchon=names&suite=all&section=all)).
Install either the **prebuilt signed EFI binary**
(`curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi`) or build locally
with the repo Makefile / `generate-zbm` (Perl `Sort::Versions`, `YAML::PP`, `boolean`; image
needs `fzf`, `kexec-tools`, `mbuffer`; on Debian/Ubuntu it builds with `dracut` from
`dracut-core`) — [overview](https://docs.zfsbootmenu.org/en/latest/),
[Debian UEFI guide](https://docs.zfsbootmenu.org/en/latest/guides/debian/uefi.html).
This is a real maintenance cost: you pin a binary or maintain a build. (Ubuntu packaging:
**UNVERIFIED**.)

Its Debian (UEFI) guide is materially simpler than the HOWTO:

- **Single pool** `zroot` (no `bpool`), created with `zpool create -f -o ashift=12
  -O compression=lz4 -O acltype=posixacl -O xattr=sa -O relatime=on -o autotrim=on
  -o compatibility=openzfs-2.3-linux -m none zroot …`.
- Separate **512 MiB ESP** holding the ZFSBootMenu EFI binary; `zroot/ROOT/${ID}` with
  `canmount=noauto`; `bootfs` set.
- `debootstrap trixie /mnt`; install `linux-image-amd64`, `zfs-initramfs`;
  `echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf`.
- Copy `VMLINUZ.EFI` to `/boot/efi/EFI/ZBM/`, plus a `-BACKUP.EFI` copy; add `efibootmgr`
  entries.
- The guide calls the compatibility flag "a conservative choice" and warns that ZFSBootMenu
  release binaries are "generally built with the latest stable release of ZFS", so check
  release notes before removing the flag.

Requirements are structural, not layout-prescriptive
([Boot Environments primer](https://docs.zfsbootmenu.org/en/latest/general/bootenvs-and-you.html)):
≥1 importable pool; a filesystem with `mountpoint=/` (unless `org.zfsbootmenu:active=off`)
or `mountpoint=legacy` with `org.zfsbootmenu:active=on`; and a paired kernel+initramfs under
its `/boot`. **No separate `/boot` pool is required.** It supports native encryption, but
"it's critical that `keyformat` is set to `passphrase`"
([native encryption](https://docs.zfsbootmenu.org/en/latest/general/native-encryption.html)).
There is an [mdraid redundant-ESP guide](https://docs.zfsbootmenu.org/en/latest/general/mdraid-esp.html)
and a [migration-from-GRUB guide](https://docs.zfsbootmenu.org/en/latest/general/grub-migration.html)
whose endpoint is destroying the old `bpool` and removing GRUB.

**Why it matters:** ZFSBootMenu removes GRUB's pool-feature constraint, so you do not need a
feature-limited `bpool` — one pool, one code path — and boot environments (snapshots/clones)
become first-class.

### 6.4 curtin / Subiquity / MAAS / cloud-init (Ubuntu path)

- **Subiquity** is Ubuntu's server installer. The autoinstall reference documents
  `storage.layout.name` with supported layouts "`lvm`, `direct` and `zfs`"
  ([autoinstall reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)).
  There is **no top-level `zpool` key**; custom ZFS is expressed as actions under
  `storage.config` using a "superset of that supported by curtin".
- **RAIDZ/mirror in Subiquity is NOT documented.** The guided `zfs` layout creates a
  single-vdev pool on one disk (Subiquity source `guided_zfs` builds one partition and one
  `rpool`), and the storage how-to's RAID section covers only MD RAID 0/1/5/6/10
  ([storage how-to](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/configure-storage.html)).
  Treat "Subiquity has documented RAIDZ/mirror ZFS layouts" as **false**.
- **`zsys` is removed from Ubuntu.** Launchpad shows zsys 0.5.11.3build4 "Removal requested
  on 2025-05-05" and "Deleted on 2025-05-05 … unmaintained and shouldn't be used anymore"
  ([Launchpad](https://launchpad.net/ubuntu/questing/amd64/zsys),
  [bug #2109962](https://bugs.launchpad.net/ubuntu/+source/zsys/+bug/2109962)). It exists only
  in 22.04/24.04 archives. The OpenZFS HOWTO had already called it "on life support"
  ([guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)).
  But Subiquity's guided ZFS still emits `zsys`-style datasets (`rpool/ROOT/ubuntu_<uuid>`,
  `rpool/USERDATA/...`, a separate `bpool/BOOT/ubuntu_<uuid>`, `org.zsys:bootfs`) — so
  inheriting an Ubuntu ZFS layout gives you Ubuntu-shaped boot environments.
- **curtin** is the low-level installer ("take data from a source, and get it onto disk as
  quickly as possible and then boot it") used by Subiquity/MAAS
  ([curtin overview](https://curtin.readthedocs.io/en/latest/topics/overview.html)). Its ZFS
  root support is **Experimental**: the storage doc marks "Zpool Command (`zpool`)"
  **Experimental** and "ZFS Command (`zfs`)" **Experimental**, and describes `fstype:
  zfsroot` similarly ([curtin storage](https://curtin.readthedocs.io/en/latest/topics/storage.html)).
  Its `zpool` action takes a flat `vdevs:` list with no documented raidz/mirror syntax.
- **cloud-init** is instance configuration, not disk imaging. Subiquity's own docs state
  cloud-init "does not process the autoinstall directives itself"
  and "becomes inert for every subsequent reboot"
  ([interaction](https://canonical-subiquity.readthedocs-hosted.com/en/latest/explanation/cloudinit-autoinstall-interaction.html)).
  Debian's release notes point to `cloud-init` only for the **cloud images**
  ([release-notes §3.3](https://www.debian.org/releases/trixie/release-notes/installing.en.html)).

### 6.5 Recommendation

Combine **(a) build once** — an `mmdebstrap`-based golden Debian 13 root dataset with
ZFSBootMenu or GRUB — with **(b) stamp many** — per-machine `zpool create` +
`zfs recv` + first-boot identity regeneration.

---

## 7. Q5 — Is "boot Ubuntu live and run a script" sound? Concrete pitfalls

It can work, but the Ubuntu live-server image as shipped is a poor fit, and the version skew
is dangerous unless pinned.

### 7.1 OpenZFS feature-flag / pool-version skew — the biggest pitfall

- Debian trixie ships **OpenZFS 2.3.9** (`zfsutils-linux`/`zfs-dkms` `2.3.9-0+deb13u1`, in
  `contrib`) ([zfsutils-linux](https://packages.debian.org/trixie/zfsutils-linux)).
  The tracker lists trixie's current security version as `2.3.9-0+deb13u1`, with
  testing/unstable at `2.4.4-1` ([tracker](https://tracker.debian.org/pkg/zfs-linux)).
- Ubuntu 26.04 LTS "Resolute Raccoon" ships **OpenZFS 2.4.1**
  (`zfsutils-linux 2.4.1-1ubuntu5.1`) ([packages.ubuntu.com](https://packages.ubuntu.com/resolute/zfsutils-linux));
  its release notes say "ZFS has been updated to the latest 2.4.1 version"
  ([changes](https://documentation.ubuntu.com/release-notes/26.04/changes-since-previous-interim/)).
- `zpool create` enables **all supported features** by default
  ([zpool-create(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-create.8.html)),
  and feature flags *are* the on-disk format: "ZFS pool on-disk format versions are specified
  via 'features' which replace the old on-disk format numbers", and an **active** feature's
  support "is required to import the pool in read-write mode"
  ([zpool-features(7)](https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html)).
  A pool created by Ubuntu's 2.4.1 with everything enabled can therefore be unimportable
  read-write on trixie's 2.3.9.

**Mitigation (verified available):** create every pool with an explicit compatibility set
trixie understands, e.g. `-o compatibility=openzfs-2.3-linux`. Compatibility files are read
from `/etc/zfs/compatibility.d` or `/usr/share/zfs/compatibility.d`, and "only features
present in all files are enabled"
([zpool-features(7)](https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html)).
Both Debian trixie and Ubuntu 26.04 ship `/usr/share/zfs/compatibility.d/openzfs-2.3-linux`
([Debian filelist](https://packages.debian.org/trixie/amd64/zfsutils-linux/filelist),
[Ubuntu filelist](https://packages.ubuntu.com/resolute/amd64/zfsutils-linux/filelist)),
so the Ubuntu live environment can create a trixie-importable pool. The ZFSBootMenu Debian
guide uses exactly this flag. Do **not** rely on `zpool upgrade` to fix a mismatch — it moves
the pool forward, not backward.

### 7.2 The live distro's ZFS tooling and module differ from Debian's

- Ubuntu's OpenZFS page: "On Ubuntu, ZFS is included in the default Linux kernel packages"
  ([OpenZFS Ubuntu](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/index.html)).
  Ubuntu's `zfsutils-linux` recommends only `zfs-zed`, no `zfs-modules`/`zfs-dkms`
  ([Ubuntu package](https://packages.ubuntu.com/resolute/zfsutils-linux)).
- Debian offers ZFS **only as DKMS source** in `contrib`
  ([wiki.debian.org/ZFS](https://wiki.debian.org/ZFS)). So the Ubuntu live kernel's ZFS and
  the trixie target's DKMS build are different builds entirely.

### 7.3 The Ubuntu 26.04 live-server image does not even ship `zpool`/`zfs`

This is a concrete blocker, verified from the ISO manifest:

- The live-server manifest lists only `linux-main-modules-zfs-7.0.0-30-generic` — i.e. the
  **kernel module**, not the userspace tools. `zfsutils-linux` is **not** in the live
  filesystem ([manifest](https://releases.ubuntu.com/26.04/ubuntu-26.04.1-live-server-amd64.manifest)).
- The `.deb` is present on the ISO (`/pool/main/z/zfs-linux/zfsutils-linux_2.4.1-1ubuntu5_amd64.deb`,
  alongside `libzfs7linux`, `libzpool7linux`, `zfs-zed`, `zfs-dracut`), so it can be
  installed offline ([ISO .list](https://releases.ubuntu.com/26.04/ubuntu-26.04.1-live-server-amd64.list)) —
  and Canonical's own ZFS autoinstall example does exactly that with
  `early-commands: - apt-get install -y zfsutils-linux`
  ([ai-zfs-guided.yaml](https://raw.githubusercontent.com/canonical/subiquity/main/examples/ai-zfs-guided.yaml)).
- **`debootstrap` and `mmdebstrap` are not in the live-server manifest or ISO list.** So the
  "boot Ubuntu live and run a script" plan must first install `debs` from the ISO or the
  network before it can do anything ZFS- or Debian-bootstrap-related.

### 7.4 `/etc/hostid` mismatch, pool auto-import, and the "last accessed by another system" error

- `zgenhostid` "Creates /etc/hostid file and stores the host ID in it"; the value "must be
  unique among your systems" ([zgenhostid(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zgenhostid.8.html)).
  `spl_hostid=0` means the hostid is disabled; it "can be explicitly enabled by placing a
  unique non-zero value in /etc/hostid" ([spl(4)](https://openzfs.github.io/openzfs-docs/man/master/4/spl.4.html)).
- "A pool records the `hostid` of the system that imported it. If another system sees a pool
  that a different host still has imported, it refuses to import it"; "a missing or
  duplicated hostid is a classic cause of pools that either refuse to import after a hostname
  change or fail to protect themselves in a cluster"
  ([Boot Process](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Operations/Boot%20Process.html)).
- The exact failure is documented as [ZFS-8000-EY](https://openzfs.github.io/openzfs-docs/msg/ZFS-8000-EY/index.html):
  `cannot import 'test': pool may be in use from other system, it was last accessed by
  'tank' (hostid: 0x1435718c) … use '-f' to import anyway`. `-f` "Forces import, even if the
  pool appears to be potentially active"
  ([zpool-import(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-import.8.html)).
- ZFSBootMenu documents both the golden-image hazard and the fix: its initramfs/EFI bundle
  copies the host `/etc/hostid` in, and you can override the embedded `<hostid>`; its default
  `zbm.import_policy=hostid` "will attempt to adopt the hostid of the system that last
  imported the pool" ([zfsbootmenu(7)](https://docs.zfsbootmenu.org/en/latest/man/zfsbootmenu.7.html)).

### 7.5 Ubuntu-specific tooling: `zsys`

`zsys` is **removed from the Ubuntu archive** (deleted from questing on 2025-05-05,
[Launchpad](https://launchpad.net/ubuntu/questing/amd64/zsys),
[bug #2109962](https://bugs.launchpad.net/ubuntu/+source/zsys/+bug/2109962)), so a current
Ubuntu 26.04 live environment will not run it. The residual risk is **layout inheritance**:
Subiquity's guided `zfs` still creates `zsys`-style datasets (`rpool/ROOT/ubuntu_<uuid>`,
separate `bpool/BOOT/ubuntu_<uuid>`, `org.zsys:bootfs`), so do not adopt that layout for a
Debian target. The OpenZFS HOWTO also calls `zsys` "on life support"
([guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)).

### 7.6 dpkg foreign-arch

Running `debootstrap`/`mmdebstrap` for trixie inside an Ubuntu live environment mixes two
distributions. `mmdebstrap` supports "foreign architecture chroots with qemu-user"
([README](https://salsa.debian.org/debian/mmdebstrap/-/raw/master/README.md)), but its
default `--arch` must be executable by the host kernel; if target arch ≠ host arch you need
`--foreign` and `qemu-user-static`. `debootstrap` likewise needs `--foreign`
([Debian installation guide D.3](https://www.debian.org/releases/trixie/amd64/apds03.en.html)).
Practical rule: keep `--arch=amd64` on amd64 and do not `dpkg --add-architecture` on the live
host.

### 7.7 apt sources

Point the target at Debian, not Ubuntu: the HOWTO uses
`deb http://deb.debian.org/debian trixie main contrib non-free-firmware`
([guide Step 1](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)).
Include `contrib` (ZFS is there) and `non-free-firmware` as needed. Verify your script writes
the target's `sources.list` rather than inheriting the live host's.

### 7.8 Running `mmdebstrap` inside the live env

Fine in principle — `mmdebstrap` "requires apt and is thus limited to Debian and
derivatives", which is about the *host*, not the target
([README](https://salsa.debian.org/debian/mmdebstrap/-/raw/master/README.md)). But on the
Ubuntu 26.04 **live-server** image you must install it first (§7.3), and you need `gpg`
(a Recommends) for archive verification plus a resolvable `/etc/resolv.conf` copied into the
chroot ([ZFSBootMenu guide](https://docs.zfsbootmenu.org/en/latest/guides/debian/uefi.html)).

### 7.9 Verdict

Sound **only if**: (1) every `zpool create` pins `-o compatibility=openzfs-2.3-linux`;
(2) you install `zfsutils-linux` and the bootstrap tool into the live env first; (3) you do
not adopt Subiquity/`zsys` layouts; (4) you write Debian apt sources; (5) you handle hostid
and identity. Otherwise it is a fleet-wide foot-gun. A **Debian live ISO** — which both the
OpenZFS and ZFSBootMenu guides use — removes the version-skew and missing-tooling problems
entirely and is strictly lower-risk.

---

## 8. Q6 — Multi-disk specifics, and how the 1-SSD case differs

### 8.1 `zpool create` for mirror / raidzN

From the HOWTO ([Step 2](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)):

```sh
# mirror
zpool create ... rpool mirror /dev/disk/by-id/DISK1-part4 /dev/disk/by-id/DISK2-part4
# raidz / raidz2 / raidz3
zpool create ... rpool raidz  DISK1-part4 DISK2-part4 DISK3-part4
```

The manpage confirms multi-vdev forms (`mirror sda sdb mirror sdc sdd`) and notes that
mixing redundancy levels or differently-sized devices is an error unless `-f` is given
([zpool-create(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-create.8.html)).
Debian's wiki gives the same patterns and redundancy minimums (mirror ≥2, raidz1 ≥3,
raidz2 ≥4) ([wiki.debian.org/ZFS](https://wiki.debian.org/ZFS)). Use `/dev/disk/by-id/*`
and partition each disk identically in the same order.

### 8.2 ashift for SSD/NVMe

- `ashift` is a **pool property** (documented in zpoolprops(7), not on the create page):
  "Values from 9 to 16 … 0 (the default) means to auto-detect"; "when performance is
  important and the underlying disks use 4KiB sectors but report 512B sectors … set
  `ashift=12`"; and critically, "Changing this value will not modify any existing vdev, not
  even on disk replacement" ([zpoolprops(7)](https://openzfs.github.io/openzfs-docs/man/master/7/zpoolprops.7.html)).
- The HOWTO recommends `ashift=12` for the same reason and notes a future replacement drive
  may require it ([guide Step 2](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)).
- Debian's wiki adds that some SSDs have 8 KiB physical sectors and suggests considering
  `ashift=12` **or `ashift=13`**, warning that mixing a larger-sector device into a
  wrongly-aligned vdev "can severely impact performance"
  ([wiki.debian.org/ZFS](https://wiki.debian.org/ZFS)).

`ashift=12` is the documented default choice; `ashift=13` only for devices that report
8 KiB physical sectors. `autotrim` is also a pool property (default `off`) and the manpage
warns it "can put significant stress on the underlying storage devices"
([zpoolprops(7)](https://openzfs.github.io/openzfs-docs/man/master/7/zpoolprops.7.html)).

### 8.3 Mirroring the ESP and installing the bootloader on every disk

- The HOWTO creates a 512 MiB ESP per disk and, at first boot, mirrors it: for UEFI,
  `dd if=DISK1-part2 of=DISK2-part2` then
  `efibootmgr -c -g -d DISK2 -p 2 -L "debian-2" -l '\EFI\debian\grubx64.efi'`; for BIOS,
  `dpkg-reconfigure grub-pc` with all disks selected ([guide Step 6.8](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)).
- The Ubuntu guide uses `dpkg-reconfigure grub-efi-amd64` and additionally **masks
  `grub-initrd-fallback.service`** because `/boot/grub/grubenv` does not work on
  mirrored/raidz topologies ([Ubuntu 22.04 guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html)).
- ZFSBootMenu documents a cleaner redundant-ESP approach with mdraid level-1 using
  `--metadata 1.0` (metadata at the end of the partition so firmware still sees a valid ESP),
  `mkfs.vfat -F32 /dev/md/esp`, mounted at `/boot/efi`, and "if adding boot entries with
  efibootmgr, add entries for each disk" ([mdraid ESP](https://docs.zfsbootmenu.org/en/latest/general/mdraid-esp.html)).
  It also keeps a `-backup.EFI` bundle with its own EFI entry
  ([UEFI booting](https://docs.zfsbootmenu.org/en/latest/general/uefi-booting.html)).

**Why mirror the ESP:** ZFS mirrors protect pool data, not the FAT ESP; if only disk 1's ESP
is populated and only disk 1 has an EFI boot entry, disk 1 is a single point of boot failure.

### 8.4 systemd-boot vs GRUB for ZFS root

- **systemd-boot** is UEFI-only and **does not read ZFS**: it loads entries from the ESP (and
  optional XBOOTLDR), and "kernels, initrds and other EFI images to boot generally need to
  reside on the ESP or the Extended Boot Loader partition"; kernels need `CONFIG_EFI_STUB`
  ([systemd-boot](https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html)).
  So the `/boot` files must live on FAT (ESP or XBOOTLDR), which is why the ESP must be sized
  for kernels+initramfs. "systemd-boot supports ZFS" is **UNVERIFIED/false** — it simply does
  not need ZFS support because it never reads the pool.
- **GRUB** reads ZFS but only a subset of features. The HOWTO: "GRUB does not support all
  zpool features (see `spa_feature_names` in `grub-core/fs/zfs/zfs.c`). We create a separate
  zpool for /boot here, specifying the `-o compatibility=grub2` property which restricts the
  pool to only those features that GRUB supports, allowing the root pool to use any/all
  features" ([guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)).
  GRUB's own manual page for the module is one line ("This module provides support for the
  ZFS file system in GRUB") ([GRUB manual](https://www.gnu.org/software/grub/manual/grub/html_node/zfs_005fmodule.html)).
  OpenZFS ships `/usr/share/zfs/compatibility.d/grub2`, `grub2-2.06`, `grub2-2.12`; the
  `grub2-2.06` header warns GRUB < v2.12 cannot detect a pool when a snapshot of the
  top-level boot pool exists and `extensible_dataset` is enabled
  ([zpool-features(7)](https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html)).
  Debian trixie's `zfsutils-linux` ships all three
  ([filelist](https://packages.debian.org/trixie/amd64/zfsutils-linux/filelist)).
- **Recommendation:** prefer ZFSBootMenu or sd-boot + a large ESP/XBOOTLDR for new builds;
  use GRUB only if needed, keeping the `bpool`/`compatibility=grub2` design.

### 8.5 ESP / `/boot` sizing

- The UAPI Boot Loader Specification suggests that "if on GPT and an ESP is found and it is
  large enough (let's say at least 1G) it should be used as `$BOOT`", and that the ESP/
  XBOOTLDR "must use a file system readable by the firmware. For most systems this means
  VFAT" ([Boot Loader Specification](https://uapi-group.org/specifications/specs/boot_loader_specification/)).
- OpenZFS HOWTO: **512 MiB ESP** + separate **1 GiB boot pool**, with the warning that a
  kernel+initrd is ~100 MiB and regenerated initramfs "may be around 85M each"
  ([guide Step 2](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)).
- Ubuntu 22.04 guide: **512 MiB ESP** + **2 GiB boot pool**, noting Ubuntu's installer uses
  "5% of the disk space constrained to a minimum of 500 MiB and a maximum of 2 GiB"
  ([Ubuntu guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html)).
- ZFSBootMenu Debian guide: **512 MiB ESP**, no separate boot pool
  ([guide](https://docs.zfsbootmenu.org/en/latest/guides/debian/uefi.html)).

There is **no single Debian-mandated ESP size**; the authoritative guidance found is the UAPI
"at least 1G" suggestion plus the guide conventions above. Size up if you keep multiple
kernels or ZFSBootMenu bundles.

### 8.6 ZFS native encryption with root

- `zpool create … -O encryption=on -O keylocation=prompt -O keyformat=passphrase` is
  documented directly in the HOWTO; "The boot pool is not encrypted at all … The system
  cannot boot without the passphrase being entered at the console"
  ([guide Encryption](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)).
- Upstream: `encryption=on` selects `aes-256-gcm`; `keyformat` is `passphrase` (8–512 bytes,
  PBKDF2, default 350000 iterations), `raw` (exactly 32 bytes) or `hex`; `keylocation` may be
  `prompt`, `file:///…` or `http(s)://`. **Not encrypted:** dataset/snapshot names,
  hierarchy, properties, file sizes/holes, dedup tables. `zfs change-key` only rewraps the
  master key and "does not undo a compromise"
  ([Native Encryption](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Encryption.html)).
- The HOWTO offers optional **Dropbear in initramfs** remote unlocking (`dropbear-initramfs`,
  `zfsunlock`), with the caveat that converted OpenSSH keys remain "available on-disk,
  unencrypted in the initramfs" ([guide Step 4.15](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)).
- LUKS sits *under* ZFS, so for mirrors/raidz "the data has to be encrypted once per disk"
  (vs once total for native encryption).

### 8.7 zvol swap

The HOWTO's documented recipe ([Step 7](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)):

```sh
zfs create -V 4G -b $(getconf PAGESIZE) -o compression=zle \
    -o logbias=throughput -o sync=always \
    -o primarycache=metadata -o secondarycache=none \
    -o com.sun:auto-snapshot=false rpool/swap
mkswap -f /dev/zvol/rpool/swap
echo /dev/zvol/rpool/swap none swap discard 0 0 >> /etc/fstab
echo RESUME=none > /etc/initramfs-tools/conf.d/resume
```

Two documented cautions: zvol swap "can result in lockup" under high memory pressure
(upstream [openzfs/zfs#7734](https://github.com/openzfs/zfs/issues/7734)), repeated by the
Debian wiki; and `RESUME=none` is required or "the boot process hangs for 30 seconds waiting
for the swap zvol to appear". Use `/dev/zvol/...` aliases, never `/dev/zdX`.

### 8.8 How the 1-SSD mini PC case differs

- **No mirror/raidz vdev**: `zpool create … rpool DISK-part4` (single-device pool).
- **One ESP, one bootloader**: skip the `dd`/`efibootmgr` second-disk steps. The single disk
  is unavoidably a single point of failure; there is nothing to mirror.
- **Encryption is more attractive** (physical theft risk) and adds no redundancy concern.
- **Golden image is especially effective**: one pool shape, one ESP layout, one hardware
  class → the same stream for every unit.
- Keep `ashift=12` and consider `autotrim=on`.

---

## 9. Q7 — Determinism / identity hygiene when cloning

A golden image copies per-machine identity. Scrub at least:

| Item | Why it must be unique | How to handle (source) |
|---|---|---|
| `/etc/machine-id` | "The ID of each machine should be unique." For images "created once and used on multiple machines … `/etc/machine-id` should be either missing or **an empty file**"; an ID is generated at boot; use `systemd-firstboot` on a mounted image. | [machine-id(5)](https://www.freedesktop.org/software/systemd/man/latest/machine-id.html) |
| SSH host keys | Cloned keys let clones impersonate the original and cause client warnings. | Regenerate at first boot. cloud-init's `cc_ssh` does this **by default** (`ssh_deletekeys: true`, regenerates one key per `ssh_genkeytypes`), but note cloud-init has **no machine-id module** — [cloud-init modules](https://docs.cloud-init.io/en/latest/reference/modules.html). |
| `/etc/hostid` | ZFS hostid "must be unique among your systems"; a duplicated hostid causes "pool may be in use from other system" import refusals. | [zgenhostid(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zgenhostid.8.html), [ZFS-8000-EY](https://openzfs.github.io/openzfs-docs/msg/ZFS-8000-EY/index.html), [Boot Process](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Operations/Boot%20Process.html). Generate per machine rather than copying. |
| ZFS pool GUIDs | Duplicated pool identity can confuse import/replication. | `zpool reguid` exists ([zpool-reguid(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-reguid.8.html)); using it in a clone workflow is **UNVERIFIED** — recreating the pool per machine sidesteps it. |
| Hostname | Must differ per machine. | Write `/etc/hostname` + `127.0.1.1 <host>` per machine ([HOWTO Step 4.1](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)); cloud-init `cc_set_hostname` is the cloud path ([modules](https://docs.cloud-init.io/en/latest/reference/modules.html)). |
| `zpool.cache` | Contains pool GUIDs/config. | With per-machine pool creation it is regenerated; the HOWTO copies it when installing into an existing pool. |
| Hibernation resume config | Stale swap UUID/device can hang boot. | `RESUME=none` ([HOWTO Step 7](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)). |

**Sealing pattern:** before snapshotting, truncate `/etc/machine-id` to empty (or delete it),
delete SSH host keys and `/etc/hostid`, clear `/etc/hostname`; at first boot run
`systemd-machine-id-setup`, regenerate SSH keys, `zgenhostid`, and write the hostname.
`machine-id(5)` explicitly endorses the empty-file approach for multi-machine images.
Beware: a receiving pool records the hostid from the source, so do the hostid fix **before**
the clone imports the pool in production.

---

## 10. Q8 — Idempotency, verification, and parallel provisioning

### 10.1 Making it idempotent

- **Wipe unconditionally before create:** `zpool labelclear -f`, `wipefs -a`,
  `sgdisk --zap-all` on every target disk (the ZFSBootMenu guide does exactly this; the HOWTO
  has equivalent MD/ZFS cleanup). Re-running then converges.
- **Pin the ZFS feature set** with `-o compatibility=openzfs-2.3-linux` on **every**
  `zpool create` (§7.1).
- **Use `-o cachefile=/etc/zfs/zpool.cache` and `-R /mnt`** as the HOWTO does, for a stable
  mount layout.
- **Make the bootstrap deterministic:** `mmdebstrap` is "bit-by-bit reproducible output" if
  `$SOURCE_DATE_EPOCH` is set ([README](https://salsa.debian.org/debian/mmdebstrap/-/raw/master/README.md)).
  Note that ZFS records `creation`/`createtxg` and unique pool GUIDs, so byte-identical
  *pools* are not achievable via bootstrap; byte-identical *datasets* are, via one send
  stream.
- **Prefer `zfs recv` of a fixed snapshot over re-running package installation**, so
  "success" means "the stream applied".
- **Guard `zpool export -a`** and fail loudly; the HOWTO's "pool busy" fallbacks exist
  because export is flaky.

### 10.2 Verify before trusting

- `zpool status` / `zpool import` listing for vdev health; `zpool status -t` for TRIM
  ([wiki.debian.org/ZFS](https://wiki.debian.org/ZFS)).
- `zfs get -r keystatus,encryptionroot pool` for encrypted datasets
  ([Native Encryption](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Encryption.html)).
- `grub-probe /boot` and mount checks from the HOWTO.
- Boot each machine **and boot from each redundant disk in turn** to prove ESP mirroring and
  per-disk bootloader entries.
- Diff identity material across two deployed machines (`machine-id`, SSH keys, `/etc/hostid`,
  pool GUID, hostname).
- Confirm `zfs.ko` loaded from the DKMS build, and that it survives a kernel upgrade.

### 10.3 Parallel provisioning

- **Golden-image path parallelises cleanly:** pool creation + `zfs recv` is I/O-bound and
  independent per machine; run N live environments concurrently against a local mirror or a
  cached stream. No shared DKMS build.
- **Bootstrap path parallelises with a shared bottleneck:** downloads and DKMS compiles are
  CPU/network heavy; use a local apt mirror/cache (`mmdebstrap` supports multiple mirrors) or
  build the root once. **No first-party throughput number** for parallel ZFS-root
  provisioning exists that I found — **UNVERIFIED**.
- **No official Debian/OpenZFS "provision N ZFS-root hosts" tool** was found; the
  orchestration layer is yours — **UNVERIFIED**.

---

## 11. Q9 — Real risks and required verification

1. **Feature-flag/pool-version mismatch (highest risk).** Ubuntu 26.04 = OpenZFS 2.4.1,
   trixie = 2.3.9; `zpool create` enables all supported features by default. Mitigate with
   `-o compatibility=openzfs-2.3-linux` and test a trixie import before rollout
   ([zpool-create](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-create.8.html),
   [zpool-features](https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html),
   [Ubuntu](https://packages.ubuntu.com/resolute/zfsutils-linux),
   [Debian](https://packages.debian.org/trixie/zfsutils-linux)).
2. **DKMS fragility.** `zfs.ko` is rebuilt per kernel upgrade; without matching
   `linux-headers` there is no module. "The modules will be built automatically only for
   kernels that have the corresponding linux-headers package installed"
   ([wiki.debian.org/ZFS](https://wiki.debian.org/ZFS)); ZFSBootMenu sets
   `REMAKE_INITRD=yes` to force initramfs regeneration after DKMS builds
   ([guide](https://docs.zfsbootmenu.org/en/latest/guides/debian/uefi.html)).
3. **Secure Boot blocks unsigned DKMS modules.** "By default, this will block out-of-tree
   modules including DKMS-managed drivers"; DKMS modules "will be signed using a machine
   owner key (MOK)" ([wiki.debian.org/SecureBoot](https://wiki.debian.org/SecureBoot)). Without
   a MOK enrolment (`dkms generate_mok`, `mokutil --import /var/lib/dkms/mok.pub`), ZFS will
   not load. This is a hard gating risk for Secure Boot fleets.
4. **Bootloader single point of failure** unless the ESP is mirrored and each disk has an EFI
   boot entry (§8.3).
5. **Clone identity leakage** — `machine-id`, SSH host keys, `/etc/hostid`, pool GUIDs; the
   machine ID "should be considered 'confidential'"
   ([machine-id(5)](https://www.freedesktop.org/software/systemd/man/latest/machine-id.html)).
6. **Native-encryption metadata leak** — names, hierarchy, properties, file sizes/holes are
   not encrypted; use LUKS underneath if that matters
   ([Native Encryption](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Encryption.html)).
7. **zvol swap lockups / resume hang** ([guide Step 7](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html),
   [openzfs/zfs#7734](https://github.com/openzfs/zfs/issues/7734)).
8. **Preseed assumption is a dead end** — no `partman-zfs` for Linux, no `zfs` method
   ([search](https://packages.debian.org/search?suite=all&searchon=names&keywords=partman-zfs),
   [README.Debian](https://sources.debian.org/src/zfs-linux/2.3.9-0+deb13u1/debian/README.Debian/)).
9. **Licensing/organisational.** Because trixie ZFS is DKMS source in `contrib`, internal
   redistribution of prebuilt `zfs.ko` binaries may be legally sensitive — the same reason
   Debian keeps them out of `main`
   ([bug #861263](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=861263),
   [wiki.debian.org/ZFS](https://wiki.debian.org/ZFS)).
10. **Ubuntu live-ISO drift.** The live environment's OpenZFS changes with point releases
    (26.04.1 is current); pin the ISO by checksum and record its `zfsutils-linux` version.
    And remember the live-server image ships the ZFS module but **not** `zpool`/`zfs` or the
    Debian bootstrap tools (§7.3).

**Required verification checklist**

- [ ] Create a pool exactly as the script does; import it read-write on a real trixie install,
      mount a dataset, run `zpool status`.
- [ ] Confirm `zfs.ko` loads from DKMS on trixie for the target kernel, and after a simulated
      kernel upgrade.
- [ ] Boot the installed system end-to-end; then repeat boot from each redundant disk.
- [ ] For encrypted builds, confirm `keystatus=available` after unlocking and that
      `RESUME=none` is set.
- [ ] Diff identity material across two deployed machines.
- [ ] Re-run the script against an already-provisioned machine and confirm idempotency.
- [ ] If Secure Boot is on, confirm MOK enrolment lets the module load.

---

## 12. Concrete recommendations

1. **Do not wait for the installer.** `partman-zfs` is not in trixie (it was a kFreeBSD-only
   udeb, removed), there is no `zfs` preseed method, and Debian's own package README says
   `debian-installer` "does not support root installation". Plan around it entirely.
2. **Adopt a two-stage pipeline:** build one golden Debian 13 root dataset; deploy it with
   `zfs send | zfs recv`. This removes per-machine DKMS/apt cost, the dominant time sink.
3. **Use `mmdebstrap`, not `debootstrap`,** for the golden build and set
   `$SOURCE_DATE_EPOCH`. Expect roughly 2–6× faster bootstrap per the tool's own numbers
   (not a guarantee for your hardware).
4. **Pin `-o compatibility=openzfs-2.3-linux` on every `zpool create`.** Most important guard
   given the Ubuntu-2.4.1 / Debian-2.3.9 skew.
5. **Prefer ZFSBootMenu's single-pool Debian design over the HOWTO's `bpool`/`rpool` split**
   for new fleet builds. If you must keep GRUB, keep `bpool` with `-o compatibility=grub2`.
6. **Multi-disk servers:** create the pool per machine with the correct `mirror`/`raidzN`
   topology and `ashift=12`; receive the golden root; mirror the ESP and register an EFI boot
   entry on **every** disk (or use ZFSBootMenu's mdraid ESP pattern).
7. **1-SSD mini PCs:** single-device pool, single ESP, golden-image deploy; enable native
   encryption if theft is in the threat model.
8. **Generate identity at first boot, never clone it:** empty `/etc/machine-id`, delete SSH
   host keys and `/etc/hostid` before sealing; run `systemd-machine-id-setup`, key
   regeneration and `zgenhostid` on first boot (cloud-init can do host keys and hostname, but
   **not** machine-id).
9. **If you insist on "Ubuntu live + script":** prefer a **Debian** live ISO; otherwise
   install `zfsutils-linux` + your bootstrap tool into the live env first (they are not on
   the 26.04 live-server image), pin the compatibility flag on every pool, never adopt
   Subiquity/`zsys` layouts, keep `--arch=amd64`, and write Debian apt sources explicitly.
10. **Treat prebuilt-module redistribution as a legal question**, and Secure Boot/MOK as a
    deployment gate.

---

## 13. Risks / open questions (including UNVERIFIED items)

- **UNVERIFIED:** a first-party "clone a Debian ZFS root to new hardware" guide. The
  `zfs send/recv` and clone mechanics are documented ([Snapshots and Clones](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Datasets/Snapshots%20and%20Clones.html),
  [zfs-receive(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-receive.8.html)),
  but the end-to-end root-pool clone/boot procedure is not spelled out upstream.
- **UNVERIFIED:** `zpool reguid` as a per-clone step in this workflow
  ([zpool-reguid(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-reguid.8.html)
  exists, but no procedure found).
- **UNVERIFIED:** cloud-init regenerating `/etc/machine-id` — there is **no** `cc_machine_id`
  module and the string does not appear in the module reference; host-key regeneration via
  `cc_ssh` **is** documented ([modules](https://docs.cloud-init.io/en/latest/reference/modules.html)).
- **UNVERIFIED:** any published benchmark for provisioning a *ZFS root* specifically; all
  cited numbers are generic chroot-bootstrap timings.
- **UNVERIFIED:** Ubuntu packaging status for `zfsbootmenu` (Debian confirmed absent).
- **UNVERIFIED:** curtin targeting a Debian (non-Ubuntu) install; curtin's docs describe the
  Ubuntu/MAAS path, and its ZFS actions are marked Experimental.
- **UNVERIFIED / false as stated:** "systemd-boot supports ZFS" — it does not read ZFS;
  kernels/initrds must be on the FAT ESP/XBOOTLDR
  ([systemd-boot](https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html)).
- **UNVERIFIED as a quote:** an explicit OpenZFS statement "do not use the distro installer";
  the evidence is directional, not verbatim.
- **UNVERIFIED as phrased:** that ZFSBootMenu "solves the initramfs-upgrade problem" — the
  docs make the verifiable claim that it removes the separate GRUB-compatible `bpool`
  ([migration guide](https://docs.zfsbootmenu.org/en/latest/general/grub-migration.html)).
- **Risk:** Ubuntu ≥26.04 UI drift — `ubuntu.com/about/release-cycle` currently 404s; the
  maintained list is at
  [ubuntu.com/project/docs/release-team/list-of-releases](https://ubuntu.com/project/docs/release-team/list-of-releases/).
- **Risk:** the 26.04 live-server image lacks `zfsutils-linux`, `debootstrap` and
  `mmdebstrap`, so a naive script fails immediately.
- **Risk:** `mmdebstrap` benchmark numbers come from the tool author on 2015-era hardware with
  a localhost mirror and tmpfs.

---

## 14. Q4 addendum — Ubuntu release facts (as of 2026-09-17)

For the record, since the team proposed "Ubuntu 26.04":

- **Ubuntu 26.04 LTS "Resolute Raccoon" is released** (2026-04-23), and **26.04.1** shipped
  2026-08-27. The current LTS is 26.04; the most recent released version is 26.04.1 LTS
  ([releases.ubuntu.com](https://releases.ubuntu.com/),
  [Canonical announcement](https://canonical.com/blog/canonical-releases-ubuntu-26-04-lts-resolute-raccoon),
  [26.04 schedule](https://documentation.ubuntu.com/release-notes/26.04/schedule/)).
- The most recent **interim** is 25.10 "Questing Quokka" (2025-10-10), already **EOL** (9
  months, July 2026) ([25.10 release notes](https://documentation.ubuntu.com/release-notes/25.10/)).
  The next interim is **26.10 "Stonking Stingray"**, scheduled 2026-10-15
  ([26.10 schedule](https://documentation.ubuntu.com/release-notes/26.10/schedule/)).
- Ubuntu OpenZFS versions: 26.04 = **2.4.1**; 26.10 (dev) = 2.4.4; 25.10 = 2.3.4;
  24.04 = 2.2.2; 22.04 = 2.1.5
  ([packages.ubuntu.com search](https://packages.ubuntu.com/search?keywords=zfsutils-linux)).
- `wiki.ubuntu.com/Releases` is now just a redirect to the project-docs list-of-releases page;
  `ubuntu.com/about/release-cycle` currently returns 404.

---

## 15. Source index (all primary)

**OpenZFS**
- [Debian Trixie Root on ZFS](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html)
- [Debian index](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/index.html) · [Ubuntu index](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/index.html) · [Ubuntu 22.04 guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html)
- manpages: [zpool-create](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-create.8.html) · [zpoolprops](https://openzfs.github.io/openzfs-docs/man/master/7/zpoolprops.7.html) · [zpool-features](https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html) · [zpool-import](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-import.8.html) · [zpool-export](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-export.8.html) · [zfs-send](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-send.8.html) · [zfs-receive](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-receive.8.html) · [zgenhostid](https://openzfs.github.io/openzfs-docs/man/master/8/zgenhostid.8.html) · [zpool-reguid](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-reguid.8.html) · [spl(4)](https://openzfs.github.io/openzfs-docs/man/master/4/spl.4.html)
- [Native Encryption](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Encryption.html) · [Send and Receive](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Operations/Send%20and%20Receive.html) · [Boot Process](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Operations/Boot%20Process.html) · [Snapshots and Clones](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Datasets/Snapshots%20and%20Clones.html)
- [ZFS-8000-EY](https://openzfs.github.io/openzfs-docs/msg/ZFS-8000-EY/index.html) · [openzfs/zfs#7734](https://github.com/openzfs/zfs/issues/7734) · [compatibility.d commit](https://github.com/openzfs/zfs/commit/bffdb048cccd16874fb7a325792a13034a3d5947.patch)

**Debian**
- [packages.debian.org/trixie/zfsutils-linux](https://packages.debian.org/trixie/zfsutils-linux) · [zfs-dkms](https://packages.debian.org/trixie/zfs-dkms) · [zfs-initramfs](https://packages.debian.org/trixie/zfs-initramfs) · [zfs-zed](https://packages.debian.org/trixie/zfs-zed) · [zfs-modules](https://packages.debian.org/trixie/zfs-modules) · [mmdebstrap](https://packages.debian.org/trixie/mmdebstrap) · [debootstrap](https://packages.debian.org/trixie/debootstrap)
- [trixie zfsutils-linux filelist](https://packages.debian.org/trixie/amd64/zfsutils-linux/filelist) · [linux-image-amd64 filelist (no zfs.ko)](https://packages.debian.org/trixie/amd64/linux-image-6.12.107+deb13-amd64/filelist) · [partman-zfs search](https://packages.debian.org/search?suite=all&searchon=names&keywords=partman-zfs)
- [tracker.debian.org/pkg/zfs-linux](https://tracker.debian.org/pkg/zfs-linux) · [tracker.debian.org/pkg/partman-zfs](https://tracker.debian.org/pkg/partman-zfs) · [partman-zfs control](https://salsa.debian.org/installer-team/partman-zfs/-/raw/master/debian/control)
- [Debian bug #861263 (wontfix)](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=861263) · [bug #648109](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=648109) · [bug #1091428](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1091428)
- [zfs-linux README.Debian](https://sources.debian.org/src/zfs-linux/2.3.9-0+deb13u1/debian/README.Debian/) · [wiki.debian.org/ZFS](https://wiki.debian.org/ZFS) · [wiki.debian.org/SecureBoot](https://wiki.debian.org/SecureBoot)
- [release notes §3](https://www.debian.org/releases/trixie/release-notes/installing.en.html) · [release notes §5](https://www.debian.org/releases/trixie/release-notes/issues.en.html) · [installation guide §6.3](https://www.debian.org/releases/trixie/amd64/ch06s03.en.html) · [preseeding B.4.8](https://www.debian.org/releases/trixie/amd64/apbs04.en.html) · [cross-install D.3](https://www.debian.org/releases/trixie/amd64/apds03.en.html)
- [mmdebstrap README](https://salsa.debian.org/debian/mmdebstrap/-/raw/master/README.md) · [mmdebstrap manpage](https://manpages.debian.org/trixie/mmdebstrap/mmdebstrap.1.en.html)

**Ubuntu / Canonical**
- [releases.ubuntu.com](https://releases.ubuntu.com/) · [26.04 schedule](https://documentation.ubuntu.com/release-notes/26.04/schedule/) · [26.10 schedule](https://documentation.ubuntu.com/release-notes/26.10/schedule/) · [25.10 notes](https://documentation.ubuntu.com/release-notes/25.10/) · [list of releases](https://ubuntu.com/project/docs/release-team/list-of-releases/) · [26.04 announcement](https://canonical.com/blog/canonical-releases-ubuntu-26-04-lts-resolute-raccoon)
- [resolute zfsutils-linux](https://packages.ubuntu.com/resolute/zfsutils-linux) · [resolute filelist](https://packages.ubuntu.com/resolute/amd64/zfsutils-linux/filelist) · [zsys removal](https://launchpad.net/ubuntu/questing/amd64/zsys) · [zsys bug #2109962](https://bugs.launchpad.net/ubuntu/+source/zsys/+bug/2109962)
- [26.04.1 live-server manifest](https://releases.ubuntu.com/26.04/ubuntu-26.04.1-live-server-amd64.manifest) · [26.04.1 ISO .list](https://releases.ubuntu.com/26.04/ubuntu-26.04.1-live-server-amd64.list) · [ai-zfs-guided.yaml](https://raw.githubusercontent.com/canonical/subiquity/main/examples/ai-zfs-guided.yaml)
- [Subiquity autoinstall reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html) · [storage how-to](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/configure-storage.html) · [cloud-init interaction](https://canonical-subiquity.readthedocs-hosted.com/en/latest/explanation/cloudinit-autoinstall-interaction.html)
- [curtin overview](https://curtin.readthedocs.io/en/latest/topics/overview.html) · [curtin storage](https://curtin.readthedocs.io/en/latest/topics/storage.html) · [cloud-init modules](https://docs.cloud-init.io/en/latest/reference/modules.html)

**Bootloaders / specs**
- [ZFSBootMenu overview](https://docs.zfsbootmenu.org/en/latest/) · [Debian UEFI guide](https://docs.zfsbootmenu.org/en/latest/guides/debian/uefi.html) · [Boot Environments](https://docs.zfsbootmenu.org/en/latest/general/bootenvs-and-you.html) · [native encryption](https://docs.zfsbootmenu.org/en/latest/general/native-encryption.html) · [mdraid ESP](https://docs.zfsbootmenu.org/en/latest/general/mdraid-esp.html) · [GRUB migration](https://docs.zfsbootmenu.org/en/latest/general/grub-migration.html) · [snapshot management](https://docs.zfsbootmenu.org/en/latest/online/snapshot-management.html) · [zfsbootmenu(7)](https://docs.zfsbootmenu.org/en/latest/man/zfsbootmenu.7.html)
- [systemd-boot](https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html) · [machine-id(5)](https://www.freedesktop.org/software/systemd/man/latest/machine-id.html) · [Boot Loader Specification](https://uapi-group.org/specifications/specs/boot_loader_specification/) · [GRUB zfs module](https://www.gnu.org/software/grub/manual/grub/html_node/zfs_005fmodule.html)
