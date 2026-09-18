# Bootloader and LUKS notes for Debian 13 "trixie" root-on-ZFS

**Research date:** 2026-09-17 (UTC). Package versions and "current" statements are pinned to that date.

**Scope:** Boot-media/bootloader facts for Debian 13 "trixie" with ZFS root on machines that must be
PXE-capable, headless (no IPMI/iDRAC), mostly UEFI but with some legacy-BIOS machines; and LUKS
(not ZFS-native) full-disk encryption for a root pool where nobody can type a boot passphrase.

**Method:** primary sources only — upstream project documentation, man pages, specs, project source
repositories, Debian package tracker pages and Debian bug logs. Each non-obvious claim carries an
inline link to the source that owns it, with short verbatim quotes where they settle a question.
Anything not confirmable from a primary source is marked **UNVERIFIED**. No facts, quotes, package
versions or release dates are invented.

**Conventions:** URLs were fetched on 2026-09-17. `zpool-features(7)` and the OpenZFS man pages are
cited at `master`; the OpenZFS Debian Trixie HOWTO is the page that owns the Debian-specific
procedure. "The guide" below means the OpenZFS *Debian Trixie Root on ZFS* page unless stated.

---

## 1. ZFSBootMenu: legacy BIOS support vs UEFI-only EFI binary

**Short answer: ZFSBootMenu does support legacy BIOS. The prebuilt *EFI executable* is UEFI-only, but
the project also ships separate kernel + initramfs components that any standard BIOS bootloader
(e.g. syslinux/extlinux) can boot, and ZFSBootMenu then reads the ZFS pool itself and `kexec`s the
real kernel. There is no native ZFSBootMenu BIOS binary; on BIOS you boot the ZFSBootMenu kernel
with a third-party BIOS loader.**

How ZFSBootMenu is launched, from its own overview:

> "Via direct EFI booting, an EFI boot manager like `rEFInd`, a BIOS bootloader like `syslinux`, or
> some other means, boot a ZFSBootMenu image (as either a self-contained UEFI application or a
> dedicated Linux kernel and initramfs)."
> — <https://docs.zfsbootmenu.org/en/latest/>

Binary-release forms, from the project's release docs:

> "Each release includes pre-generated boot images ... These images are available for `x86_64` UEFI
> and legacy BIOS systems in the form of an EFI executable or a kernel and initramfs."
> — <https://docs.zfsbootmenu.org/en/latest/>

> "The EFI executables should be directly bootable by most UEFI firmware implementations or boot
> managers including rEFInd, gummiboot and systemd-boot. ... In addition, the separate components
> may be booted by any standard BIOS boot loader (_e.g._, syslinux) on legacy hardware."
> — <https://docs.zfsbootmenu.org/en/latest/general/binary-releases.html>

The UEFI-booting page states the BIOS case explicitly:

> "Although ZFSBootMenu images can be booted on legacy BIOS systems or (on other platforms)
> alternative firmware, ZFSBootMenu integrates nicely with modern UEFI systems."
> — <https://docs.zfsbootmenu.org/en/latest/general/uefi-booting.html>

**Exactly how BIOS boot works** (from the project's own BIOS guide, Void Linux SYSLINUX MBR):

1. Label the disk MBR/DOS and create a boot partition plus the ZFS partition:
   `sfdisk` with `label: dos`, `start=1MiB, size=512MiB, type=83, bootable`.
2. Format the boot partition ext4 (`mkfs.ext4 -O '^64bit'`), mount at `/boot/syslinux`.
3. Install syslinux: `extlinux --install /boot/syslinux`, copy `/usr/lib/syslinux/*.c32`, and write
   the syslinux MBR: `dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr.bin of="$BOOT_DISK"`.
4. Point `syslinux.cfg` at the generated ZFSBootMenu pair, e.g. `KERNEL /zfsbootmenu/vmlinuz-bootmenu`
   and `INITRD /zfsbootmenu/initramfs-bootmenu.img` with `APPEND zfsbootmenu quiet`.
   — <https://docs.zfsbootmenu.org/en/latest/guides/void-linux/syslinux-mbr.html>

The guide is Void-specific in its OS-install steps but is the project's canonical BIOS procedure; the
boot-menu wiring (`syslinux.cfg` → kernel + initramfs) is distribution-independent. In this mode
**syslinux/extlinux is the BIOS loader; ZFSBootMenu is a kernel**, not a BIOS binary — the ZFS
reading and menu happen inside the ZFSBootMenu initramfs, and the final kernel is launched by
`kexec`.

**PXE:** the task asked to check for a PXE guide. No ZFSBootMenu documentation page describing a PXE
/TFTP boot procedure was found on docs.zfsbootmenu.org as of 2026-09-17. The overview's "or some
other means" and the syslinux route imply a PXE-capable BIOS loader could chain the kernel+initramfs,
but the project does **not** document a supported PXE path. **PXE via ZFSBootMenu: UNVERIFIED**, and
the team should not rely on ZFSBootMenu docs for PXE.

---

## 2. Is GRUB required to boot a ZFS root from legacy BIOS on Debian?

**Short answer: for the procedure Debian and OpenZFS actually document, yes — the OpenZFS *Debian
Trixie Root on ZFS* guide uses GRUB for both BIOS and UEFI, and `grub-pc` is Debian's BIOS GRUB
package. It is not the only loader that can do it (ZFSBootMenu + syslinux is the documented
alternative, §1), but it is the only one the Debian root-on-ZFS guide covers, and it is what the
guide means by "legacy (BIOS) booting".**

What the guide says about BIOS/legacy vs UEFI:

- System requirements: *"Installing on a drive which presents 4 KiB logical sectors (a '4Kn' drive)
  only works with UEFI booting. This is not unique to ZFS. GRUB does not and will not work on 4Kn
  with legacy (BIOS) booting."*
- Partitioning: *"Run this if you need legacy (BIOS) booting:"* `sgdisk -a1 -n1:24K:+1000K -t1:EF02 $DISK`;
  *"Run this for UEFI booting (for use now or in the future):"* `sgdisk -n2:1M:+512M -t2:EF00 $DISK`.
- Bootloader install (Step 4.10) offers *"one of the following options"*: BIOS → `apt install --yes grub-pc`;
  UEFI → `apt install --yes dosfstools`, `mkdosfs -F 32 ...`, mount ESP, `apt install --yes grub-efi-amd64 shim-signed`.
- Step 5.6: *"For legacy (BIOS) booting, install GRUB to the MBR:"* `grub-install $DISK` —
  *"Note that you are installing GRUB to the whole disk, not a partition. If you are creating a
  mirror or raidz topology, repeat the `grub-install` command for each disk in the pool."*
- Step 5.3 works around GRUB's feature limits via `GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/debian"`.
  — <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

So on Debian, the supported/documented BIOS path for ZFS root is GRUB with a BIOS Boot Partition
(type `EF02`) and `grub-install` to the MBR. The alternative documented by the bootloader's own
project (ZFSBootMenu + syslinux, §1) avoids GRUB entirely, and also avoids the need for a separate
GRUB-compatible `bpool` (§3), because ZFSBootMenu reads the full-featured root pool itself.

**The separate `bpool`:** the OpenZFS guide unconditionally creates a second pool named `bpool` for
`/boot`, in addition to `rpool` for `/`. It is not optional in that guide: Step 4.2 creates
`zfs create -o canmount=off -o mountpoint=none bpool/BOOT` and `zfs create -o mountpoint=/boot bpool/BOOT/debian`,
and Step 4.13 adds a `zfs-import-bpool.service` to always import it. See §3 for why.

---

## 3. Why a separate `bpool`, and why `-o compatibility=grub2`

**Short answer: because GRUB's ZFS reader implements only a subset of OpenZFS on-disk features. The
`bpool` is the pool GRUB must read (it holds `/boot`, i.e. the kernel and initramfs), so it is created
with `-o compatibility=grub2` to enable only the features GRUB understands. The root pool `rpool` is
*not* read by GRUB — the kernel/initramfs reads it — so it is created normally and may use all
features.**

The guide says this directly:

> "_Note:_ GRUB does not support all zpool features (see `spa_feature_names` in
> [grub-core/fs/zfs/zfs.c](https://git.savannah.gnu.org/cgit/grub.git/tree/grub-core/fs/zfs/zfs.c#288)).
> We create a separate zpool for `/boot` here, specifying the `-o compatibility=grub2` property which
> restricts the pool to only those features that GRUB supports, allowing the root pool to use any/all
> features."
> — <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

The mechanism is owned by `zpool-features(7)`. A "compatibility feature set" is a list of feature
names; when set via `-o compatibility=…`, *"Only features present in all files are enabled."* OpenZFS
ships `/usr/share/zfs/compatibility.d/grub2`, whose header is:

> "# Features which are supported by GRUB2 versions from v2.12 onwards."
> — <https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html>

and a stricter `grub2-2.06` file, whose header explains the actual failure mode:

> "# Features which are supported by GRUB2 versions prior to v2.12.
> # GRUB is not able to detect ZFS pool if snapshot of top level boot pool is created. This issue is
> observed with GRUB versions before v2.12 if `extensible_dataset` feature is enabled on ZFS boot
> pool. This file lists all read-only compatible features except `extensible_dataset` and any other
> feature that depends on it."
> — <https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html>

The same man page shows the intended invocation: `zpool create -o compatibility=grub2 bootpool vdev`.
For grounding, GRUB's own reader holds a hard read-only allow-list of ZFS features (e.g. `lz4_compress`,
`hole_birth`, `embedded_data`, `extensible_dataset`, `large_blocks`, `vdev_zaps_v2`, `head_errlog`,
`zstd_compress`) in `spa_feature_names` — this is the list the guide's note points at.
— <https://git.savannah.gnu.org/cgit/grub.git/tree/grub-core/fs/zfs/zfs.c> (the guide cites
`grub-core/fs/zfs/zfs.c#288`).

Consequences for the team:

- Keep `/boot` (the GRUB-readable content) in a `compatibility=grub2` pool, and keep the kernel +
  initramfs there; put the root filesystem in a full-feature `rpool`.
- A loader that reads ZFS itself at full feature level (ZFSBootMenu) removes the need for `bpool`
  entirely, because nothing outside the ZFSBootMenu image needs to parse the boot pool.
- Note the guide's `bpool` `-o compatibility=grub2` also constrains which features can later be
  enabled on that pool; `zpool upgrade` will not enable features outside the set.

---

## 4. Does systemd-boot (sd-boot) read ZFS?

**Short answer: no. sd-boot is UEFI-only and loads kernels/initrds/UKIs from FAT filesystems — the
ESP and/or an XBOOTLDR partition. It has no ZFS support. If `/boot` is on ZFS, sd-boot cannot read
it; the kernel and initramfs must be copied to the FAT ESP/XBOOTLDR.**

systemd-boot(7) is explicit about firmware scope:

> "**systemd-boot** (short: **sd-boot**) is a simple UEFI boot manager. ... **systemd-boot** supports
> systems with UEFI firmware only."
> — <https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html>

and about where the payload must live:

> "**systemd-boot** loads boot entry information from the EFI system partition (ESP), usually mounted
> at `/efi/`, `/boot/`, or `/boot/efi/` during OS runtime, as well as from the Extended Boot Loader
> partition (XBOOTLDR) if it exists (usually mounted to `/boot/`). Configuration file fragments,
> kernels, initrds and other EFI images to boot generally need to reside on the ESP or the Extended
> Boot Loader partition. Linux kernels must be built with `CONFIG_EFI_STUB` to be able to be directly
> executed as an EFI image."
> — <https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html>

The Boot Loader Specification (UAPI.1), which sd-boot implements, requires those partitions to be
firmware-readable:

> "For systems where the firmware is able to read file systems directly, the ESP and XBOOTLDR must
> use a file system readable by the firmware. For most systems this means VFAT (16 or 32 bit)."
> — <https://uapi-group.org/specifications/specs/boot_loader_specification/>

The spec defines the GPT type GUIDs — ESP `c12a7328-f81f-11d2-ba4b-00a0c93ec93b`, XBOOTLDR
`bc13c2ff-59e6-4262-a352-b275fd6f7172` — and defines `$BOOT` as the XBOOTLDR if present, otherwise
the ESP; Type #1 entry `linux`/`initrd` values are *"a path relative to the root of the file system
containing the boot entry snippet itself."* It also explicitly notes that referencing kernels on
other partitions is *"out of focus ... by design."* — <https://uapi-group.org/specifications/specs/boot_loader_specification/>

The Discoverable Partitions Specification reinforces this: it lists the ESP's permitted file system as
**VFAT** — <https://uapi-group.org/specifications/specs/discoverable_partitions_specification/>.

**Practical consequence:** sd-boot is compatible with ZFS *root* only if `/boot` (kernel + initramfs
or a UKI) is on the FAT ESP/XBOOTLDR and ZFS lives on the root partition(s). It cannot boot a
"kernel inside a ZFS dataset" layout without a separate FAT boot partition. sd-boot reading a ZFS
pool is not merely unsupported — it is outside what the loader does at all.

---

## 5. One disk bootable under BOTH UEFI and legacy BIOS (hybrid GPT: ESP + BIOS Boot Partition)

**Short answer: yes, in principle. GPT is explicitly usable on BIOS platforms by GRUB, which uses a
dedicated "BIOS Boot Partition" (GPT type `0xEF02` / GUID `21686148-6449-6e6f-744e656564454649`), and
a UEFI ESP (type `EF00` / GUID `c12a7328-…`) can exist on the same GPT disk. The OpenZFS guide
creates both partition types and gives install commands for each loader, but it tells you to choose
one at install time and does not document a combined hybrid install.**

GRUB's own manual, "BIOS installation → GPT":

> "Some newer systems use the GUID Partition Table (GPT) format. This was specified as part of the
> Extensible Firmware Interface (EFI), but it can also be used on BIOS platforms if system software
> supports it; for example, GRUB and GNU/Linux can be used in this configuration. With this format,
> it is possible to reserve a whole partition for GRUB, called the BIOS Boot Partition. GRUB can then
> be embedded into that partition ... If you are using gdisk, set the partition type to '0xEF02'.
> With partitioning programs that require setting the GUID directly, it should be
> '21686148-6449-6e6f-744e656564454649'."
> — <https://doc.guix.gnu.org/grub/2.14/en/html_node/BIOS-installation.html>

The UEFI-side partition is owned by the Boot Loader Specification (ESP GPT GUID), and its FAT
requirement is quoted in §4. — <https://uapi-group.org/specifications/specs/boot_loader_specification/>

What the OpenZFS Debian Trixie guide does:

- It gives **both** partition commands in Step 2 and labels them by purpose: *"Run this if you need
  legacy (BIOS) booting:"* (`-t1:EF02`) and *"Run this for UEFI booting (for use now or in the
  future):"* (`-t2:EF00`). A reader who runs both ends up with both partitions on the GPT disk.
- But bootloader installation is *"Choose one of the following options"* — `grub-pc` for BIOS **or**
  `grub-efi-amd64` for UEFI — and Step 5.6 installs to the MBR **or** to the ESP, not both.
  — <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

**Verdict:** the guide covers the *partition layout* for both modes (it creates EF02 + EF00) but does
**not** document installing both GRUB targets. A hybrid install is possible by doing both — install
`grub-pc` and run `grub-install $DISK` (MBR/BIOS Boot Partition) **and** install `grub-efi-amd64` and
run `grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian` — with the
GRUB core image on each disk. The official guide does not spell out that combined procedure; treat
the exact hybrid recipe as **partially documented / UNVERIFIED by the guide itself**, though each half
is fully documented and the two partition types are documented as coexisting on GPT.

**Conflict to flag:** Debian's own trixie installation guide states *"Booting from a disk with GPT is
only possible in native UEFI mode"* (<https://www.debian.org/releases/trixie/amd64/install.en.txt>).
That contradicts the GRUB manual and the OpenZFS guide's BIOS path (EF02 + `grub-install $DISK` to the
MBR on a GPT disk). The GRUB-manual/OpenZFS behaviour is the authoritative one for GRUB; Debian's
sentence appears to be an over-simplification about the Debian *installer*, not a limit of GPT+BIOS
booting. Do not use the Debian prose to conclude hybrid or GPT+BIOS is impossible.

---

## 6. Mirror / raidz pool: making every disk independently bootable

This is the highest-risk part of a headless deployment: ZFS redundancy does **not** by itself make a
disk bootable. The kernel/initramfs (or GRUB) has to be present on *each* disk's boot partition, and
firmware has to have a boot entry for *each*. bpool mirroring (§3) only makes the ZFS data redundant;
it does not replicate the loader or the ESP.

### 6.1 BIOS/legacy: install GRUB to every disk

The guide, Step 6.8 ("Mirror GRUB"), for legacy BIOS:

> "For legacy (BIOS) booting: `dpkg-reconfigure grub-pc`. Hit enter until you get to the device
> selection screen. Select (using the space bar) all of the disks (not partitions) in your pool."
> — <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

and earlier, Step 5.6: *"If you are creating a mirror or raidz topology, repeat the `grub-install`
command for each disk in the pool."* So on BIOS, `grub-install` each whole disk (each disk needs its
own BIOS Boot Partition of type `EF02` from Step 2, which the guide says to repeat *"for all the disks
which will be part of the pool"*).

### 6.2 UEFI: mirror the ESP and add an EFI entry per disk

The guide, Step 6.8, for UEFI, copies the ESP and creates a firmware entry on the second disk:

> `dd if=/dev/disk/by-id/scsi-SATA_disk1-part2 of=/dev/disk/by-id/scsi-SATA_disk2-part2`
> `efibootmgr -c -g -d /dev/disk/by-id/scsi-SATA_disk2 -p 2 -L "debian-2" -l '\EFI\debian\grubx64.efi'`

with *"For the second and subsequent disks (increment debian-2 to -3, etc.)"*. In Step 3/4 the guide
notes for the initial install: *"For a mirror or raidz topology, this step only installs GRUB on the
first disk. The other disk(s) will be handled later."*
— <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

`efibootmgr` is also the mechanism ZFSBootMenu documents for creating firmware entries for its own
kernel/initramfs or bundled EFI executable: `efibootmgr --disk /dev/sda --part 1 --create --label
"ZFSBootMenu" --loader '\EFI\zbm\vmlinuz-…' --unicode '… initrd=\EFI\zbm\initramfs-… quiet'`
— <https://docs.zfsbootmenu.org/en/latest/general/uefi-booting.html>. Its flags are `-c` (create
entry), `-d` (disk), `-p` (partition), `-L` (label), `-l` (loader) — <https://manpages.debian.org/trixie/efibootmgr/efibootmgr.8.en.html>.

### 6.3 ZFSBootMenu's redundant-ESP pattern (mdraid)

ZFSBootMenu documents an mdraid-based pattern that shares one FAT filesystem across the per-disk
ESPs, so `generate-zbm` writes once and every disk's ESP is updated. From *Managing Redundant ESPs
with mdraid*:

1. Create an ESP on each disk: `sgdisk -n "1:1m:+512m" -t "1:ef00" "$disk"` for each disk.
2. Create a RAID1 array with **metadata 1.0**:
   `mdadm --create --verbose --level 1 --metadata 1.0 --homehost any --raid-devices 2 /dev/md/esp /dev/sda1 /dev/sdb1`,
   then `mdadm --assemble --scan` and append to `/etc/mdadm.conf`.
3. `mkfs.vfat -F32 /dev/md/esp`, add `/dev/md/esp /boot/efi vfat defaults 0 0` to `/etc/fstab`, mount.
4. Install ZFSBootMenu in `/boot/efi`. *"If adding boot entries with `efibootmgr`, add entries for
   each disk in the mdraid array."*
   — <https://docs.zfsbootmenu.org/en/latest/general/mdraid-esp.html>

The page explains the critical constraint:

> "This configuration exploits the fact that, with version 1.0, `mdraid` metadata will be written to
> the _end_ of each partition. Newer metadata versions would be written to the beginning of each
> partition, and the system firmware would fail to recognize each component as a valid EFI system
> partition."
> — <https://docs.zfsbootmenu.org/en/latest/general/mdraid-esp.html>

It also notes the usual mdraid data-integrity concerns are acceptable for an ESP, and that an
alternative is a `generate-zbm` post-generation hook to copy images between ESPs
(`contrib/esp-sync.sh`) — *"but that requires generating images yourself."*
— <https://docs.zfsbootmenu.org/en/latest/general/mdraid-esp.html>,
<https://raw.githubusercontent.com/zbm-dev/zfsbootmenu/v3.1.0/contrib/esp-sync.sh>

### 6.4 What this means for the team

- For a mirror/raidz pool, per-disk boot requires three separate replicated things: (1) the boot
  partition contents (ESP copy or mdraid-shared ESP, or BIOS Boot Partition), (2) the bootloader
  installed on each disk, and (3) a firmware boot entry per disk (`efibootmgr`), unless using
  removable-media fallback paths or `shim`/`grub` fallback (`\EFI\BOOT\BOOTX64.EFI`) which the fetched
  pages do not document as part of this procedure (**UNVERIFIED** here).
- ZFSBootMenu + syslinux (BIOS) removes the `bpool`/GRUB-feature constraint but requires the ZFSBootMenu
  kernel+initramfs on a BIOS-loadable partition on each disk (syslinux `extlinux --install` per disk,
  MBR `dd` per disk — the syslinux guide shows the single-disk commands; per-disk repetition is the
  obvious extension and is how the guide's GRUB mirroring works, but ZFSBootMenu does not spell out a
  multi-disk BIOS procedure).
- The mdraid-ESP pattern is the least-manual way to keep mirrored ESPs in sync with ZFSBootMenu.

---

## 7. LUKS under ZFS vs LUKS over ZFS

### 7.1 LUKS **under** ZFS — the ordering used for a root pool

The OpenZFS *Debian Trixie Root on ZFS* guide defines LUKS as a supported root-encryption option with
LUKS *below* the pool. Verbatim:

> "LUKS encrypts almost everything. The only unencrypted data is the bootloader, kernel, and initrd.
> The system cannot boot without the passphrase being entered at the console. Performance is good,
> but LUKS sits underneath ZFS, so if multiple disks (mirror or raidz topologies) are used, the data
> has to be encrypted once per disk."
> — <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

The recipe the guide gives:

- Partition the fourth partition as GPT type `8309` (Linux LUKS) instead of `BF00`.
- `cryptsetup luksFormat -c aes-xts-plain64 -s 512 -h sha256 ${DISK}-part4`
- `cryptsetup luksOpen ${DISK}-part4 luks1`
- `zpool create … rpool /dev/mapper/luks1`
- For mirror/raidz: *"use `/dev/mapper/luks1`, `/dev/mapper/luks2`, etc., which you will have to create
  using `cryptsetup`."*
- `/etc/crypttab`: `echo luks1 /dev/disk/by-uuid/$(blkid -s UUID -o value ${DISK}-part4) \ none luks,discard,initramfs > /etc/crypttab`
  and the guide says the `initramfs` option is *"a work-around for cryptsetup does not support ZFS"*
  (linking Ubuntu bug #1612906).
  — <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

Debian's `crypttab(5)` documents the `initramfs` option (Debian-specific, not a systemd option):

> "The initramfs hook processes the root device, any resume devices and any devices with the
> `initramfs` option set. These devices are processed within the initramfs stage of boot. As an
> example, that allows the use of remote unlocking using dropbear."
> — <https://manpages.debian.org/trixie/cryptsetup/crypttab.5.en.html>

Because LUKS sits under the pool, each disk in a mirror/raidz is a separate LUKS container and each
needs its own `crypttab` line (`luks1`, `luks2`, …). The pool is then built on the mapped devices.

### 7.2 LUKS **over** ZFS — not a supported root layout

A ZFS zvol *is* a block device (*"A zvol is a dataset exported as a block device instead of a file
system"* — <https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Datasets/ZVOLs.html>), and
cryptsetup can operate on block devices, so a LUKS container *on a zvol* is technically a
block-on-block stack for non-root data. But it is not a root layout for ZFS-root machines:

- The documented root-encryption choices in the OpenZFS Debian Trixie guide are exactly three:
  unencrypted, ZFS native encryption, and LUKS *under* ZFS.
  <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>
- Debian/Ubuntu's `cryptsetup-initramfs` tooling cannot resolve a ZFS root: Debian bug **#838001
  "cryptsetup does not support ZFS"** remains open at severity *wishlist*, merged with #820888,
  #902449, #932891 (<https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=838001>), mirrored as Ubuntu
  #1612906 (<https://bugs.launchpad.net/ubuntu/+source/cryptsetup/+bug/1612906>). This is why the
  guide needs the `initramfs` crypttab option as a workaround.
- A LUKS-over-zvol root would be circular for boot: the zvol exists only after the pool is imported,
  and the pool (root) is what you were trying to unlock.

**Verdict: LUKS-under-ZFS is what is used in practice for a root pool.** The categorical statement
that LUKS-over-ZFS is "not generally possible" is **UNVERIFIED** as a mechanism claim; what is
supportable from primary sources is that LUKS-on-zvol is *undocumented for root* and *not supported by
the standard Debian/Ubuntu initramfs unlock path*.

### 7.3 ZFS native encryption (rejected by the team, for completeness)

OpenZFS native encryption is a per-dataset property; *"a single pool can hold both encrypted and
unencrypted datasets"* and the pool *"stays fully manageable — importable, scrubbable, resilverable
and replicable — while the keys are not loaded."* It does not encrypt dataset/snapshot names or
properties. — <https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Encryption.html>

---

## 8. Unattended / unlocks-at-boot mechanisms on Debian for LUKS root

Problem statement: headless machine, no keyboard/monitor, no IPMI/iDRAC, so no one can type a LUKS
passphrase at the console. The mechanisms below are the ones Debian/upstream documents. For each:
what it is, the primary source, and the prerequisite.

### (a) Clevis + Tang (network-bound disk encryption)

Clevis is *"a pluggable framework for automated decryption. It can be used to provide automated
decryption of data or even automated unlocking of LUKS volumes."* Binding a LUKS volume generates a
strong key, adds it as an additional LUKS passphrase, and stores the encrypted JWE *"inside the LUKS
header using LUKSMeta"*; e.g. `clevis luks bind -d /dev/sda1 tang '{"url": "http://tang.local"}'`. The
initramfs-tools unlocker is enabled by rebuilding the initramfs:
`sudo update-initramfs -u -k 'all'`. Network-based unlocking needs the network in early boot: *"you
will need to specify `rd.neednet=1` as kernel argument or use `--hostonly-cmdline` when creating with
dracut."* — <https://raw.githubusercontent.com/latchset/clevis/master/README.md>

Debian ships the initramfs integration: `clevis-initramfs` *"provides integration for initramfs-tools
to automatically unlock LUKS encrypted block devices in early boot"*
(<https://packages.debian.org/trixie/clevis-initramfs>). Tang is *"a service for binding cryptographic
keys to network presence"* (<https://packages.debian.org/trixie/tang>).

- **Prerequisite:** network reachability to a Tang server at boot (plus `rd.neednet=1` or equivalent,
  and a rebuilt initramfs). Tang itself is designed as a network-presence binding service.
- Fully unattended once configured. A Clevis `tpm2` pin also exists (§8b/§9), and Clevis SSS can
  require multiple pins (e.g. Tang **or** TPM2).

### (b) systemd-cryptenroll with TPM2

`systemd-cryptenroll` *"is a tool for enrolling hardware security tokens and devices into a LUKS2
encrypted volume"*, supporting TPM2 and others; it *"supports only LUKS2 volumes, as it stores token
meta-information in the LUKS2 JSON token area."* Unlock is configured in `crypttab(5)` with
`tpm2-device=auto`. — <https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html>

systemd's `crypttab(5)` describes the mechanism: *"the key may be acquired via a TPM2 security chip.
In this case, a (during enrollment) randomly generated key — encrypted by an asymmetric key derived
from the TPM2 chip's seed key — is stored on disk/removable media, acquired via `AF_UNIX`, or stored
in the LUKS2 JSON token metadata header."* It documents `tpm2-pcrs=`, `tpm2-pin=`, `tpm2-measure-pcr=`,
and `headless=` (*"If true, never query interactively for the password/PIN. Useful for headless
systems."*). — <https://www.freedesktop.org/software/systemd/man/latest/crypttab.html>

**Critical Debian caveat (this changes the recommended path):** the default Debian initramfs is
`initramfs-tools` + `cryptsetup-initramfs`, whose `crypttab` implementation does **not** understand
systemd's `tpm2-device=` / `fido2-device=` options. The two `crypttab` formats are explicitly
different — Debian's `crypttab(5)` says:

> "Please note that there are several independent cryptsetup wrappers with their own crypttab format.
> This manpage covers Debian's implementation for initramfs scripts and SysVinit init scripts. systemd
> brings its own crypttab implementation."
> — <https://manpages.debian.org/trixie/cryptsetup/crypttab.5.en.html>

This is corroborated by Debian/Ubuntu bug reports: *"Cryptsetup-initramfs cant deal with tpm2-device
option"* (Launchpad #1980018, reported 2022, still New/confirmed; original Debian bug #1031254), which
records the initramfs-time warning `cryptsetup: WARNING: … ignoring unknown option 'tpm2-device'`, and
the 2026 Debian bug **#1137437**: classic initramfs-tools/cryptroot setups *"support `keyscript=` but
ignore `fido2-device=` `tpm2-device=`"*, while *"systemd-cryptsetup supports `fido2-device=`
`tpm2-device=` but does not support `keyscript=`"* — and *"unsupported boot-critical options are
silently ignored."*
— <https://bugs.launchpad.net/debian/+source/cryptsetup/+bug/1980018>,
<https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1137437>

- **Prerequisite:** a TPM2 chip present/discoverable, and a LUKS2 volume (LUKS1 has no JSON token
  area). On Debian trixie with the stock initramfs-tools, `systemd-cryptenroll` alone does **not**
  give boot-time auto-unlock — the token can be enrolled, but `cryptsetup-initramfs` will not consume
  it. A systemd-based initramfs (e.g. dracut) or Clevis's `clevis-tpm2` pin is required in practice.
  Do not assume `systemd-cryptenroll --tpm2-device=auto` + `crypttab` unlocks a stock trixie root.

### (c) A keyfile stored in the initramfs

`crypttab(5)` third field is the key file: *"the entire key file will be used as the passphrase; the
passphrase must not be followed by a newline character."*
— <https://manpages.debian.org/trixie/cryptsetup/crypttab.5.en.html>

By default Debian does **not** copy keyfiles into the initramfs. The Debian cryptsetup-initramfs README,
§12 "Storing keyfiles directly in the initramfs":

> "Normally devices using a keyfile are ignored (with a loud warning), and the key file itself is not
> included in the initramfs, because the initramfs image typically lives on an unencrypted `/boot`
> partition. However in some cases it is desirable to include the key file in the initramfs ... Among
> the key files listed in the crypttab(5), those matching the value of the environment variable
> `KEYFILE_PATTERN` (interpreted as a shell pattern) will be included in the initramfs image."
> — <https://cryptsetup-team.pages.debian.net/cryptsetup/README.initramfs.html>

i.e. add `KEYFILE_PATTERN="/etc/keys/*.key"` to `/etc/cryptsetup-initramfs/conf-hook` and set
`UMASK=0077`. The same pattern was the proposed LUKS-under-ZFS root recipe in Debian bug #838001.
— <https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=838001>

- **Prerequisite:** none at boot (fully unattended), but the keyfile lands in the initramfs, which
  normally lives on an unencrypted `/boot` — an explicit security trade-off. Encrypting `/boot`
  (e.g. GRUB reading LUKS) is the reason the README mentions this option.

### (d) dropbear-initramfs SSH unlock

`dropbear-initramfs` *"provides initramfs integration"* and Recommends `cryptsetup-initramfs`
(<https://packages.debian.org/trixie/dropbear-initramfs>). The OpenZFS Debian Trixie guide documents
the full setup: install `dropbear-initramfs`, put host keys in `/etc/dropbear/initramfs/`, add user
keys to `/etc/dropbear/initramfs/authorized_keys`, set a static initramfs IP in
`/etc/initramfs-tools/initramfs.conf` if needed, `update-initramfs -u -k all`, then *"SSH to the system
(as root) while it is prompting for the passphrase during the boot process. For ZFS native encryption,
run `zfsunlock`. For LUKS, run `cryptroot-unlock`."*
— <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

Debian's cryptsetup README.Debian documents the same for non-ZFS: connect over SSH during initramfs
and unlock, aimed at *"an encrypted root filesystem on headless systems where no physical access is
available."* — <https://cryptsetup-team.pages.debian.net/cryptsetup/README.initramfs.html>

- **Prerequisite:** network reachability at boot plus an SSH client holding an authorized key.
  **This is remote-*interactive*, not unattended**: a human still supplies the passphrase, just over
  SSH. It solves "no console", not "no human".

### (e) A keyfile on a removable USB device present at boot

Debian's cryptsetup-initramfs README, §10 (`passdev` keyscript): *"If you have a keyfile on a removable
device (e.g. a USB-key), you can use the passdev keyscript. It will wait for the device to appear,
mount it read-only, read the key and then unmount the device."* The key field is
`<device>:<path>[:<timeout>]`, persistent names such as `/dev/disk/by-label/myusbkey` are recommended,
and required modules must be added to `/etc/initramfs-tools/modules`.
— <https://cryptsetup-team.pages.debian.net/cryptsetup/README.initramfs.html>

`crypttab(5)` also documents `CRYPTDISKS_MOUNT` (*"Specifies the mountpoints that are mounted before
cryptdisks is invoked ... This is useful for keys on removable devices, such as cdrom, usbstick,
flashcard, etc."*) and warns that `keyscript=` *"might be ignored"* under systemd unless the device is
forced to be processed in the initramfs.
— <https://manpages.debian.org/trixie/cryptsetup/crypttab.5.en.html>

- **Prerequisite:** the USB device physically present at boot (passdev waits up to the timeout). Not
  appropriate where the machine is physically inaccessible, though it is fully unattended when the
  stick is present.

### Which of these actually fit "headless, no OOB, nobody can type a passphrase"

| Mechanism | Fully unattended? | Prerequisite |
|---|---|---|
| (a) Clevis + Tang | Yes | Network + reachable Tang server |
| (b) `systemd-cryptenroll` TPM2 | Intended yes, but **broken on stock Debian initramfs-tools** (see §9/#1137437) | TPM2 chip + LUKS2; needs systemd-based initramfs or Clevis tpm2 pin |
| (b′) Clevis `tpm2` pin | Yes | TPM2 chip (`clevis-tpm2`) |
| (c) Keyfile in initramfs | Yes | Key ends up on unencrypted `/boot` |
| (d) dropbear-initramfs | No (remote-interactive) | Network + SSH key + a human |
| (e) USB keyfile | Yes if stick present | Physical USB at boot |

---

## 9. Debian 13 (trixie) packaging / availability

All versions are exactly as printed on the fetched `packages.debian.org` pages on 2026-09-17.

| Thing | trixie status | Source |
|---|---|---|
| `clevis` | **20-1** (amd64; arm64 20-1+b1) — "automated encryption framework"; supports tang + shamir | <https://packages.debian.org/trixie/clevis> |
| `tang` | **15-2** (arch `all`) — "network-based cryptographic binding server" | <https://packages.debian.org/trixie/tang> |
| `clevis-luks` | **20-1** — "LUKS integration for clevis" | <https://packages.debian.org/trixie/clevis-luks> |
| `clevis-initramfs` | **20-1** — initramfs-tools integration; depends `clevis-luks`, `initramfs-tools` | <https://packages.debian.org/trixie/clevis-initramfs> |
| `clevis-tpm2` | **20-1** — "provides the TPM2 pin"; depends `tpm2-tools` | <https://packages.debian.org/trixie/clevis-tpm2> |
| `systemd` | **257.13-1~deb13u1** (systemd 257.x) | <https://packages.debian.org/trixie/systemd> |
| `systemd-cryptsetup` | **257.13-1~deb13u1**; `systemd` only *Recommends* it | <https://packages.debian.org/trixie/systemd> |
| `systemd-cryptenroll` | **Available**, ships in the **`systemd-cryptsetup`** package (not the `systemd` package): file list contains `/usr/bin/systemd-cryptenroll`, `/usr/share/man/man1/systemd-cryptenroll.1.gz`, `/usr/lib/x86_64-linux-gnu/cryptsetup/libcryptsetup-token-systemd-tpm2.so` | <https://packages.debian.org/trixie/amd64/systemd-cryptsetup/filelist> |
| `tpm2-tools` | **5.7-1** (amd64; arm64 5.7-1+b1) — "TPM 2.0 utilities" | <https://packages.debian.org/trixie/tpm2-tools> |
| `tpm2-tss` | **Source package only** — **4.1.3-1.2**; there is no binary package named `tpm2-tss` in trixie (`packages.debian.org/trixie/tpm2-tss` → "Package not available in this suite."). Binaries include `libtss2-esys-3.0.2-0t64` (4.1.3-1.2) etc. | <https://packages.debian.org/source/trixie/tpm2-tss>, <https://packages.debian.org/trixie/libtss2-esys-3.0.2-0t64> |
| `cryptsetup-initramfs` | **2:2.7.5-2** (Debian's classic initramfs integration) | <https://packages.debian.org/trixie/cryptsetup-initramfs> |
| `dropbear-initramfs` | **2025.89-1~deb13u1** | <https://packages.debian.org/trixie/dropbear-initramfs> |

**Answers to the literal questions:**

- **Is Clevis/Tang packaged in Debian 13 (trixie)?** Yes. `clevis` 20-1, `tang` 15-2, plus
  `clevis-luks`, `clevis-initramfs`, `clevis-tpm2` all present in trixie main.
- **Is `systemd-cryptenroll` available? What systemd version is in trixie?** Yes, available; it ships
  in `systemd-cryptsetup` **257.13-1~deb13u1**, and trixie's `systemd` is the same version.
- **Is TPM2 available via `tpm2-tools` / `tpm2-tss` in trixie?** `tpm2-tools` is **5.7-1**. `tpm2-tss`
  is a **source** package (**4.1.3-1.2**); its runtime binaries are the `libtss2-*t64` packages. There
  is no `tpm2-tss` binary package by that name.

**Packaging-level caveat (load-bearing for the design):** having the packages does not mean the boot
path works. The default trixie initramfs is `initramfs-tools` + `cryptsetup-initramfs`
(2:2.7.5-2), and that stack ignores systemd's `tpm2-device=`/`fido2-device=` crypttab options; the
semantics divergence is documented in Debian bug #1137437 (2026) and Launchpad #1980018. If the team
wants TPM2 auto-unlock on trixie with the stock initramfs, the documented working route is Clevis's
`tpm2` pin (`clevis-tpm2` + `clevis-initramfs`), or switching to a systemd-based initramfs.

---

## 10. Does LUKS at the block layer interfere with `zfs send`/`zfs recv` golden-image deployment?

**Short answer: no. `zfs send`/`recv` operates on datasets and snapshots, not on block devices or
vdevs. With LUKS *under* ZFS, ZFS sees `/dev/mapper/luksN` as an ordinary vdev, and the LUKS
header/keyslots live below the pool and are not part of any send stream. LUKS is transparent to the
ZFS data stream.**

`zfs send` *"Creates a stream representation of the second snapshot, which is written to standard
output"* (<https://openzfs.github.io/openzfs-docs/man/master/8/zfs-send.8.html>); `zfs receive`
*"Creates a snapshot whose contents are as specified in the stream provided on standard input"*
(<https://openzfs.github.io/openzfs-docs/man/master/8/zfs-recv.8.html>). The OpenZFS concept doc:
*"`zfs send` serialises a snapshot into a byte stream, and `zfs receive` turns that stream back into a
dataset. ... Streams are just bytes, so they can also be stored in a file"*
(<https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Operations/Send%20and%20Receive.html>).
cryptsetup only creates a device-mapper mapping over the block device
(<https://manpages.debian.org/trixie/cryptsetup-bin/cryptsetup.8.en.html>).

**Practical consequence (derived, not a direct quote):** a golden `zfs send` stream carries ZFS
datasets only — the per-disk LUKS containers are **not** in the stream. The destination machine must
have its own LUKS devices opened (or its pool already imported) before `zfs recv`; the LUKS passphrase
/ key material is provisioned per machine, independently of the dataset stream. This is fine for a
golden-image workflow: stream the datasets, provision LUKS per host.

**If the team ever revisits ZFS native encryption** (it has rejected it), the rules change: `zfs send -w`
(`--raw`) keeps data encrypted on the wire and *"the received dataset keeps its encryption, and its
key"*, a non-raw send requires keys loaded and produces plaintext on the wire, raw and non-raw
incrementals cannot be mixed, and `-R`/`-p` sends of encrypted datasets require `-w` or `-U`.
— <https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Encryption.html>,
<https://openzfs.github.io/openzfs-docs/man/master/8/zfs-send.8.html>

---

## 11. Bottom line for this fleet

1. **Legacy BIOS is supported by ZFSBootMenu, but only as kernel+initramfs booted by a real BIOS
   loader (syslinux/extlinux).** The EFI executable is UEFI-only. GRUB is the loader the OpenZFS
   Debian trixie guide uses for BIOS (`grub-pc`, BIOS Boot Partition `EF02`, `grub-install $DISK`).
2. **A separate `bpool` exists solely because GRUB cannot parse all OpenZFS features.** It is created
   with `-o compatibility=grub2`; `rpool` is full-featured because the kernel/initramfs reads it. A
   full-feature loader (ZFSBootMenu) removes the `bpool` requirement.
3. **sd-boot cannot read ZFS**; it needs kernel + initramfs (or UKI) on the FAT ESP/XBOOTLDR.
4. **Hybrid UEFI+BIOS on one GPT disk is possible** (ESP + BIOS Boot Partition); the guide creates
   both partition types but documents installing one loader, not both.
5. **Every disk needs its own boot chain**: per-disk ESP (copied or mdraid-shared) or BIOS Boot
   Partition, the loader installed on each, and an EFI entry per disk (`efibootmgr`).
6. **Use LUKS under ZFS**, per disk, with a `crypttab` `…,initramfs` line per disk. LUKS over ZFS is
   not a supported root layout.
7. **For fully unattended unlock on stock trixie, Clevis+Tang or a Clevis tpm2 pin (or an initramfs
   keyfile) are the documented routes; `systemd-cryptenroll` TPM2 tokens are ignored by
   cryptsetup-initramfs.** dropbear-initramfs needs a human; USB keyfiles need physical presence.
8. **LUKS does not interfere with `zfs send`/`recv`** golden-image deployment; the stream is
   dataset-level and LUKS is below the pool.
9. **PXE via ZFSBootMenu is undocumented** — do not treat ZFSBootMenu as the PXE answer without
   independent verification.

---

## 12. Source index (all primary)

- ZFSBootMenu overview — <https://docs.zfsbootmenu.org/en/latest/>
- ZFSBootMenu binary releases — <https://docs.zfsbootmenu.org/en/latest/general/binary-releases.html>
- ZFSBootMenu UEFI booting — <https://docs.zfsbootmenu.org/en/latest/general/uefi-booting.html>
- ZFSBootMenu redundant ESPs with mdraid — <https://docs.zfsbootmenu.org/en/latest/general/mdraid-esp.html>
- ZFSBootMenu Void Linux SYSLINUX MBR guide — <https://docs.zfsbootmenu.org/en/latest/guides/void-linux/syslinux-mbr.html>
- OpenZFS Debian Trixie Root on ZFS — <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>
- OpenZFS zpool-features(7) — <https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html>
- OpenZFS zfs-send(8) — <https://openzfs.github.io/openzfs-docs/man/master/8/zfs-send.8.html>
- OpenZFS zfs-recv(8) — <https://openzfs.github.io/openzfs-docs/man/master/8/zfs-recv.8.html>
- OpenZFS Native Encryption — <https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Encryption.html>
- OpenZFS Send and Receive — <https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Operations/Send%20and%20Receive.html>
- OpenZFS ZVOLs — <https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Datasets/ZVOLs.html>
- GNU GRUB Manual 2.14, BIOS installation (GPT / BIOS Boot Partition) — <https://doc.guix.gnu.org/grub/2.14/en/html_node/BIOS-installation.html>
- GNU GRUB Manual 2.14, Invoking grub-install — <https://doc.guix.gnu.org/grub/latest/en/html_node/Invoking-grub_002dinstall.html>
- GRUB source, `grub-core/fs/zfs/zfs.c` (`spa_feature_names` allow-list) — <https://git.savannah.gnu.org/cgit/grub.git/tree/grub-core/fs/zfs/zfs.c>
- Debian 13 trixie installation guide (contains the contrary GPT+BIOS claim) — <https://www.debian.org/releases/trixie/amd64/install.en.txt>
- efibootmgr(8), trixie — <https://manpages.debian.org/trixie/efibootmgr/efibootmgr.8.en.html>
- systemd-boot(7) — <https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html>
- UAPI.1 Boot Loader Specification — <https://uapi-group.org/specifications/specs/boot_loader_specification/>
- UAPI.2 Discoverable Partitions Specification — <https://uapi-group.org/specifications/specs/discoverable_partitions_specification/>
- ZFSBootMenu `contrib/esp-sync.sh` — <https://raw.githubusercontent.com/zbm-dev/zfsbootmenu/v3.1.0/contrib/esp-sync.sh>
- systemd-cryptenroll(1) — <https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html>
- systemd crypttab(5) — <https://www.freedesktop.org/software/systemd/man/latest/crypttab.html>
- Debian crypttab(5) (cryptsetup 2:2.7.5-2, trixie) — <https://manpages.debian.org/trixie/cryptsetup/crypttab.5.en.html>
- Debian Cryptsetup Initramfs integration README — <https://cryptsetup-team.pages.debian.net/cryptsetup/README.initramfs.html>
- Clevis upstream README — <https://raw.githubusercontent.com/latchset/clevis/master/README.md>
- Debian bug #838001 "cryptsetup does not support ZFS" — <https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=838001>
- Debian bug #1137437 "Inconsistent crypttab semantics between cryptsetup-initramfs and systemd-cryptsetup" — <https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1137437>
- Launchpad bug #1980018 "Cryptsetup-initramfs cant deal with tpm2-device option" — <https://bugs.launchpad.net/debian/+source/cryptsetup/+bug/1980018>
- Debian package pages (trixie): clevis, tang, clevis-luks, clevis-initramfs, clevis-tpm2, systemd,
  systemd-cryptsetup, tpm2-tools, tpm2-tss (source), cryptsetup-initramfs, dropbear-initramfs —
  see inline links in §9.
