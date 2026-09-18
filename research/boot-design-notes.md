# Boot-design verification notes for Debian 13 "trixie" root-on-ZFS

**Scope.** Primary-source verification of the proposed design: **no ZFS-reading bootloader**;
`/boot` (real kernel + initramfs) on an **ext4** partition, optionally **mdadm RAID1** across
disks; initramfs imports the ZFS root pool; **GRUB** for both UEFI and legacy BIOS; no `bpool`,
no ZFSBootMenu; ZFS root pool on **LUKS** containers.

**Method.** Each claim is traced to the document or source file that owns it (upstream manual,
upstream source, Debian packaging, Debian manpage, OpenZFS manpage/source). Secondary write-ups
are not used. Where a claim could not be confirmed from a primary source it is marked
**UNVERIFIED**; where a primary source contradicts it that is stated explicitly.

**Date of verification:** 2026-09-17. Debian suite: trixie (stable). OpenZFS trixie is 2.3.x;
the OpenZFS `master` manpages cited below are the current upstream text and the `v2.3` variants
live under the same host (e.g. `.../man/v2.3/7/zpoolprops.7.html`).

---

## 1. GRUB 2 and mdadm RAID: levels and metadata versions

**Verdict: CONFIRMED.** GRUB 2 reads Linux mdadm arrays itself through its `diskfilter`
layer. It parses the md superblock and reconstructs the array from its member devices; no
`mdadm` binary, initramfs, or kernel md driver is involved at boot.

**Two mdraid drivers in GRUB source**

- **metadata 0.90** — `grub-core/disk/mdraid_linux.c`, module `mdraid09`. It locates the
  0.90 superblock near the end of the device (`sector = NEW_SIZE_SECTORS(size)`, i.e. the last
  64 KiB minus overhead), requires `major_version == 0` and `minor_version == 90`, then calls
  `grub_diskfilter_make_raid()`.
  <https://cgit.git.savannah.gnu.org/cgit/grub.git/plain/grub-core/disk/mdraid_linux.c>
- **metadata 1.x** — `grub-core/disk/mdraid1x_linux.c`, module `mdraid1x`. It loops
  `minor_version = 0,1,2` and computes the superblock location for each:
  minor 0 = near end of device (**1.0**), minor 1 = sector 0 (**1.1**), minor 2 = 4 KiB from
  start (**1.2**). It requires `major_version == 1`, validates the superblock/data layout per
  the Linux v6.8 rules, and calls `grub_diskfilter_make_raid()`.
  <https://cgit.git.savannah.gnu.org/cgit/grub.git/plain/grub-core/disk/mdraid1x_linux.c>

**RAID levels.** Both drivers accept exactly the same set and reject anything else with
`"Unsupported RAID level"`:

```
0 (stripe), 1 (mirror), 4, 5, 6, 10
```

Multipath (`level == -4`) is normalised to level 1. Spares and faulty devices are explicitly
*not* implemented (`/* Spares aren't implemented. */`), and the array is presented as a logical
disk only from the roles that are present.

**Metadata versions.** 0.90, 1.0, 1.1 and 1.2 are all supported. For the design's mdadm RAID1
`/boot`, level `1` and metadata `1.2` (mdadm's modern default) are both covered.

**Practical consequence.** GRUB can boot a kernel/initramfs that lives on an mdadm RAID1 `/boot`
with default 1.2 metadata. Because GRUB reads the members directly, `grub-install`/`grub-probe`
must be run while the array is assembled so GRUB can embed the `mdraid1x` module in the core
image.

**Debian-specific GRUB/mdraid documentation: UNVERIFIED.** Neither the Debian Grub wiki page
(<https://wiki.debian.org/Grub>) nor the Debian wiki RAID page
(<https://wiki.debian.org/SoftwareRAID>) documents GRUB's mdadm support; the RAID page covers
only `mdadm` + initramfs. The claim is verified from upstream GRUB source, not from a Debian
document.

Related but separate: GRUB's ZFS support is a curated feature allow-list, which is why a `bpool`
or `-o compatibility=grub2` exists in the ZFS-boot designs. Not needed here because `/boot` is
not ZFS. See [zpool-features(7), Compatibility feature sets](https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html).

---

## 2. syslinux / extlinux and mdadm RAID

**Verdict: syslinux is NOT an mdadm-array-aware bootloader.** It does not parse md adm
superblocks and does not assemble arrays. The syslinux wiki's "RAID" support is a BIOS
chain-retry mechanism plus a manual per-member mirror procedure.

**What the syslinux documentation actually says**

- The common `-r` option is defined as: *"Raid mode. If boot fails, tell the BIOS to boot the
  next device in the boot sequence (usually the next hard disk) instead of stopping with an
  error message. This is useful for RAID-1 booting."* This is a BIOS fallback, not array
  assembly. <https://wiki.syslinux.org/wiki/index.php?title=Doc/syslinux>
- The EXTLINUX page documents the only supported RAID layout as a **manual mirror of the
  bootloader across members**, not array reading:

  > *"If you have multiple disks in a software RAID configuration, the preferred way to boot
  > is: Create a separate RAID-1 partition for /boot ... Install the MBR on each disk, and mark
  > the RAID-1 partition as active. Run `extlinux --raid --install /boot` to install EXTLINUX.
  > This will install it on all the drives in the RAID-1 set, which means you can boot any
  > combination of drives in any order."*

  <https://wiki.syslinux.org/wiki/index.php?title=EXTLINUX> (same text in the older
  [Doc/extlinux](https://wiki.syslinux.org/wiki/index.php?title=Doc/extlinux))
- EXTLINUX is described there as a *filesystem* boot loader: it installs *"in the filesystem
  partition like a well-behaved bootloader"*. It reads the filesystem through the block device
  it was installed against; it never reads md metadata.
- There is no RAID page and no mdraid driver in the syslinux wiki navigation or source. The
  developer page only links *"Linux software RAID 1.2 superblocks"* as a mailing-list thread
  under *LVM support*: <https://wiki.syslinux.org/wiki/index.php?title=Development/LVM_support>.
- The upstream source tree `core/` contains no md/mdraid/raid metadata driver (it has disk,
  fs and network code, but no md superblock parser):
  <https://kernel.googlesource.com/pub/scm/boot/syslinux/syslinux/+/refs/heads/master/core/>

**The metadata-1.2 problem is acknowledged on the syslinux list.** The 2010 thread that led to
the wiki pointer ends with the maintainer's reply:

> *"Syslinux itself can handle it, but it will need a special boot sector (or special MBR, in
> case the entire disk in an mdraid ...) installed onto the mdraid. **I haven't written that
> code**, but it shouldn't take very long."* — H. Peter Anvin

Sources: <https://www.syslinux.org/archives/2010-June/014813.html> (question) and
<https://www.syslinux.org/archives/2010-June/014815.html> (reply). The follow-up implementation
was never an upstream feature (downstream distributions later carried patches, e.g. Fedora's
anaconda `EXTLINUX MD RAID1` change), which is exactly why this is a downstream patch and not a
syslinux capability.

**Consequence for the design.** An mdadm RAID1 `/boot` should be treated as **forcing GRUB (or
another array-aware loader)**. EXTLINUX can only be used via the "install the boot sector on
every member and hope each member is independently readable" workaround, with no md-metadata
awareness; with mdadm's default **1.2** metadata (superblock 4 KiB into the member), upstream
syslinux does not support it. **UNVERIFIED** only insofar as no syslinux wiki sentence literally
says "metadata 1.2 is unsupported today"; the source tree, the wiki's own procedure and the
maintainer's 2010 statement together establish it.

---

## 3. Debian initramfs-tools assembling mdadm arrays

**Verdict: CONFIRMED — the `mdadm` package supplies the initramfs hook and scripts.** Nothing
in initramfs-tools core assembles md arrays by itself; installing `mdadm` pulls the integration
in.

**What Debian ships** (mdadm 4.4-11, trixie, file list):

- `/usr/share/initramfs-tools/hooks/mdadm`
- `/usr/share/initramfs-tools/scripts/local-block/mdadm`
- `/usr/share/initramfs-tools/scripts/local-bottom/mdadm`

<https://packages.debian.org/trixie/amd64/mdadm/filelist>

**What the hook does** (`debian/mdadm.initramfs-hook`, installed as `hooks/mdadm`):
<https://sources.debian.org/src/mdadm/4.4-11/debian/mdadm.initramfs-hook/>

- `PREREQ="udev"`; `copy_exec /sbin/mdadm /sbin` and `copy_exec /sbin/mdmon /sbin`.
- Copies `63-md-raid-arrays.rules` and `64-md-raid-assembly.rules` from
  `/lib/udev/rules.d` or `/etc/udev/rules.d` into the image — *"Copy udev rules, which udev no
  longer does"*. Assembly in the initramfs therefore runs through **mdadm + udev incremental
  assembly**, not through a single `mdadm -A -s` call.
- Force-loads the raid modules: `linear multipath raid0 raid1 raid456 raid5 raid6 raid10`.
- Copies `/etc/mdadm/mdadm.conf` (or `/etc/mdadm.conf`) into the image. If no config exists it
  runs `/usr/share/mdadm/mkconf generate` to create one; if the config exists it comments out
  the `CREATE` line and, when there is no `ARRAY` line, regenerates a temporary config via
  `/usr/share/mdadm/mkconf`.
- `mdmon` is included so IMSM/foreign-metadata arrays can be handled.

**What must be installed/configured**

1. Install the `mdadm` package (`apt install mdadm`).
2. Have the array assembled when the initramfs is built, so `mdadm.conf` records its `ARRAY`
   line, or create one with `mdadm --detail --scan >> /etc/mdadm/mdadm.conf` (then
   `update-initramfs -u`). The Debian wiki states this explicitly: *"If you intend to have your
   root partition on the RAID device remember to regenerate the initramfs: `update-initramfs -u`.
   This is needed to embed the mdadm.conf file because the init process needs to know which
   arrays to assemble before trying to find the rootfs."*
   <https://wiki.debian.org/SoftwareRAID>
3. `mdadm.conf` syntax (`ARRAY`, `DEVICE`, `AUTO`, `metadata=` values `0.90`, `1.x`, `ddf`,
   `imsm`) is documented in [mdadm.conf(5), trixie](https://manpages.debian.org/trixie/mdadm/mdadm.conf.5.en.html).
4. The initramfs script model and the `local-block` retry mechanism are documented in
   [initramfs-tools(7), trixie](https://manpages.debian.org/trixie/initramfs-tools-core/initramfs-tools.7.en.html).

**Nuance specific to this design.** For a `/boot` that is *only* read by GRUB, the kernel does
not need the array during early boot: GRUB has already loaded the kernel+initramfs from the
array. The initramfs assembly path matters for any array the running system needs before
`switch_root` (root/usr/swap), and the normal booted system assembles all md arrays via
`mdadm`/udev/systemd. If `/boot` is expected to be *mounted* in the running system, the standard
md assembly handles it; if it is never mounted after boot, the initramfs hook for that array is
not on the boot path. Either way, installing `mdadm` and keeping `mdadm.conf` current is the
requirement, and the same hook/scripts cover both cases.

---

## 4. GRUB on UEFI: EFI binary on the ESP, kernel+initramfs from a separate ext4 `/boot`

**Verdict: CONFIRMED.**

**GRUB manual.** On EFI systems the ESP must be mounted; `grub-install` puts the EFI binary
there, while its modules and `grub.cfg` go to the *boot directory* (default `/boot`), which may
be a different filesystem:

> *"On EFI systems for fixed disk install you have to mount EFI System Partition. If you mount
> it at /boot/efi then you don't need any special arguments: `grub-install`. Otherwise you need
> to specify where your EFI System partition is mounted: `grub-install --efi-directory=/mnt/efi`."*

> *"--boot-directory=dir — Install GRUB images under the directory dir/grub/. ... If this option
> is not specified then it defaults to /boot."*

Sources:
<https://www.gnu.org/software/grub/manual/grub/html_node/Installing-GRUB-using-grub_002dinstall.html>,
<https://www.gnu.org/software/grub/manual/grub/html_node/Invoking-grub_002dinstall.html>.

**Debian wiki.** The reinstall page describes exactly this split layout and confirms the EFI
binary's location:

> *"...for a system with an EFI partition on /dev/sdb1, an unencrypted /boot partition on
> /dev/sdb2, and an unencrypted / partition on /dev/sdb3..."*
> *"Check 1. the bootloader is existing in /boot/efi/EFI/debian/grubx64.efi"*

<https://wiki.debian.org/GrubEFIReinstall>

**OpenZFS Debian Trixie guide.** UEFI install is
`grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck`,
with the `/boot` pool separate from the ESP; in the guide's legacy path it is
`grub-install $DISK`. <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

**mdadm `/boot` on UEFI.** The EFI *firmware* cannot read mdadm RAID, so the **ESP must not be
an md array** — each disk has its own FAT ESP, and they are kept in sync by copying the EFI
binary and adding an NVRAM entry per disk (the OpenZFS guide's second-disk step uses `dd` +
`efibootmgr`). The `/boot` filesystem, by contrast, *is* read by GRUB, not the firmware, so
`/boot` **can** be an mdadm RAID1 array: `grub-install` embeds the `mdraid1x` module needed to
read it (see §1). Run `grub-install`/`grub-probe` with the array assembled.

---

## 5. GRUB legacy BIOS on GPT: BIOS Boot Partition (EF02) and disk-target install

**Verdict: CONFIRMED.**

**GRUB manual, BIOS installation / GPT:**

> *"With this format, it is possible to reserve a whole partition for GRUB, called the BIOS Boot
> Partition. ... When creating a BIOS Boot Partition on a GPT system, you should make sure that
> it is at least 31 KiB in size. (GPT-formatted disks are not usually particularly small, so we
> recommend that you make it larger than the bare minimum, such as 1 MiB, to allow plenty of
> room for growth.) ... If you are using gdisk, set the partition type to '0xEF02'."*

The manual also gives the raw type GUID `21686148-6449-6e6f-744e656564454649`.

<https://www.gnu.org/software/grub/manual/grub/html_node/BIOS-installation.html>

**grub-install targets the disk, not a partition:**

> *"You must specify the device name on which you want to install GRUB ... `grub-install /dev/sda`."*

<https://www.gnu.org/software/grub/manual/grub/html_node/Invoking-grub_002dinstall.html>

**OpenZFS Debian Trixie guide** confirms both for trixie:

- legacy/BiOS partition: `sgdisk -a1 -n1:24K:+1000K -t1:EF02 $DISK` (a 1000 KiB BIOS Boot
  Partition, type EF02);
- install: `grub-install $DISK` with the note *"Note that you are installing GRUB to the whole
  disk, not a partition."* For a mirror, repeat for each disk.

<https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

**Sizing.** Minimum 31 KiB; GRUB recommends >1 MiB; the OpenZFS guide uses 1000 KiB starting at
sector 24K. A hybrid GPT that boots both UEFI and BIOS needs both the EF02 partition and the
ESP (EF00).

---

## 6. ZFS pool `compatibility` property: persistent guard on `zpool upgrade`

**Verdict: CONFIRMED.** (`zfs set` in the question is a typo — the command is **`zpool set`**.)

**The property and its persistence.** `zpoolprops(7)` defines:

> *"compatibility=off|legacy|file[,file]… — Specifies that the pool maintain compatibility with
> specific feature sets. When set to off (or unset) compatibility is disabled (all features may
> be enabled); when set to legacy no features may be enabled. When set to a comma-separated list
> of filenames ... the lists of requested features are read from those files ... Only features
> present in all files may be enabled."*

It is listed under *"The following properties can be set at creation time and import time, and
later changed with the `zpool set` command"*. The only pool properties called out as
non-persistent or import-only are `altroot` (*"not a persistent property"*) and `readonly`
(import-only). The property is therefore stored with the pool, not held in memory.
<https://openzfs.github.io/openzfs-docs/man/master/7/zpoolprops.7.html>

**Creation-time restriction.** `zpool-create(8)`:

> *"By default all supported features are enabled on the new pool. The `-d` option and the `-o`
> compatibility property (e.g `-o compatibility=2020`) can be used to restrict the features that
> are enabled, so that the pool can be imported on other releases of ZFS."*

<https://openzfs.github.io/openzfs-docs/man/master/8/zpool-create.8.html>

**Future upgrades are constrained.** `zpool-features(7)`:

> *"The requested features are applied when a pool is created using `zpool create -o
> compatibility=…` and controls which features are enabled when using `zpool upgrade`."*

`zpool-upgrade(8)`:

> *"If the pool has specified compatibility feature sets using the `-o` compatibility property,
> only the features present in all requested compatibility sets will be enabled. If this
> property is set to `legacy` then no upgrade will take place."*

<https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html>,
<https://openzfs.github.io/openzfs-docs/man/master/8/zpool-upgrade.8.html>

**Answer to the specific question.** After `zpool create -o compatibility=openzfs-2.4-linux`,
the property persists on the pool and a later `zpool upgrade` (or `zpool upgrade -a`) will only
enable features present in the `openzfs-2.4-linux` profile; it cannot silently lift the pool
above that profile. `zpool status` also stops warning about features outside the requested set
(*"zpool status will not show a warning about disabled features which are not part of the
requested feature set"*).

**Files backing the profiles.** The `openzfs-2.x` profiles ship as text files. Upstream they
live in `cmd/zpool/compatibility.d/` (the 2.3 file was added by commit
`17a2b35be577db50c19f3c1bd8f64e69abdc085b`); distributions install them under
`/usr/share/zfs/compatibility.d/`, and `/etc/zfs/compatibility.d/` overrides them.
<https://github.com/openzfs/zfs/commit/17a2b35be577db50c19f3c1bd8f64e69abdc085b>
and the manpage's Compatibility feature sets section.

- `openzfs-2.3-linux` → symlink to `openzfs-2.3` (45 features incl. `fast_dedup`,
  `large_microzap`, `raidz_expansion`).
- `openzfs-2.4-linux` → symlink to `openzfs-2.4`; it adds `block_cloning_endian`,
  `dynamic_gang_header`, `physical_rewrite`. (Verified against the profile files installed by
  OpenZFS 2.4.4 and the upstream 2.3 commit.)

**Historical caveat (fixed).** OpenZFS issue #12261 (2021): the `compatibility` property was
stored in the pool *configuration* object (like the exceptional `comment` property) instead of
the `DMU_OT_POOL_PROPS` object, so a `zpool set compatibility=…` on an existing pool could be
lost across a hard-force export / cachefile import / reboot, after which `zpool upgrade` would
enable the very features the profile excluded (the report used `draid`). Behlendorf confirmed
the cause and merged PR #12276 (2021-06-24), which keeps the value in the config object but
ensures the cachefile is written when `compatibility` changes.
<https://github.com/openzfs/zfs/issues/12261>. This is years before trixie's OpenZFS 2.3 and does
not affect pools created with `-o compatibility=…`.

**Residual risk — read this before relying on it as a hard guard.** The compatibility profile is
enforced by `zpool create` and `zpool upgrade`. The manpages do **not** state that it blocks a
manual per-feature enable. `zpool-features(7)` explicitly says only the special value `legacy`
*"...prevents any features from being enabled, either via `zpool upgrade` or `zpool set
feature@feature-name=enabled`."* The natural reading is that a non-`legacy` profile (e.g.
`openzfs-2.4-linux`) constrains create/upgrade but does **not** by itself prevent an
administrator from running `zpool set feature@some-newer-feature=enabled`. If the design needs
an absolute guard against future feature activation, `compatibility=legacy` is the only value
the manpages describe as blocking `zpool set feature@…`.

---

## 7. Changing `compatibility` after creation; narrowing does not deactivate features

**Verdict: CONFIRMED, with an important limitation.**

- **It can be changed after creation.** `zpoolprops(7)` places `compatibility` among the
  properties *"later changed with the `zpool set` command"*, and `zpool-set(8)` says
  `zpool set property=value pool` *"Sets the given property on the specified pool."*
  <https://openzfs.github.io/openzfs-docs/man/master/8/zpool-set.8.html>
- **Narrowing the profile does not turn off already-active features.** Feature state is
  one-way: `zpool-features(7)` defines `disabled` as *"This feature's on-disk format changes
  have not been made and will not be made unless an administrator moves the feature to the
  enabled state. **Features cannot be disabled once they have been enabled.**"* There is no
  operation that removes an enabled/active feature from a pool. Changing `compatibility` to a
  narrower profile therefore only affects what future `zpool upgrade` may enable; it does not
  and cannot roll back features already enabled or active.
- **`legacy` likewise does not deactivate anything.** Setting `compatibility=legacy` stops
  future upgrades and manual feature enables, but existing active features remain active.

**Operational consequence.** The compatibility profile must be chosen and set **before** the
pool is ever upgraded beyond it. Narrowing later is a forward-looking restriction only. The
same one-way property is why the profile should be set at creation time
(`zpool create -o compatibility=…`) or immediately after import and before any `zpool upgrade`.

---

## 8. LUKS2 multiple keyslots; `clevis luks bind` adds a keyslot without re-encryption

**Verdict: CONFIRMED.**

**LUKS supports multiple keyslots.** `cryptsetup(8)`:

> *"LUKS can manage multiple passphrases that can be individually revoked or changed. Each
> passphrase uses an individual keyslot containing a volume key for data encryption. Keyslots
> can be securely scrubbed from persistent media due to the use of anti-forensic stripes."*

<https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/man/cryptsetup.8.adoc>

The slot counts are hard limits in the on-disk format:

- LUKS1: `#define LUKS_NUMKEYS 8` — <https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/lib/luks1/luks.h>
- LUKS2: `#define LUKS2_OBJECTS_MAX 32`, `#define LUKS2_KEYSLOTS_MAX LUKS2_OBJECTS_MAX`,
  `#define LUKS2_TOKENS_MAX LUKS2_OBJECTS_MAX`
  — <https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/lib/luks2/luks2.h>

**A new keyslot is added without re-encrypting the data.** `cryptsetup luksAddKey`:

> *"Adds a keyslot protected by a new passphrase. An existing passphrase must be supplied
> interactively, via --key-file or LUKS2 token (plugin)."*

<https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/man/cryptsetup-luksAddKey.8.adoc>

Adding a keyslot only re-wraps the existing volume key into a new keyslot; the bulk data area is
untouched. (Re-encryption is a separate operation, `cryptsetup reencrypt`.)

**`clevis luks bind` is exactly this.** `clevis-luks-bind(1)`, trixie:

> *"This command performs four steps: 1. Creates a new key with the same entropy as the LUKS
> master key — maximum entropy bits is 256. 2. Encrypts the new key with Clevis. 3. Stores the
> Clevis JWE in the LUKS header. 4. Enables the new key for use with LUKS. This disk can now be
> unlocked with your existing password as well as with the Clevis policy."*

And its CAVEATS section:

> *"This command does not change the LUKS master key."*

<https://manpages.debian.org/trixie/clevis-luks/clevis-luks-bind.1.en.html> (clevis-luks 20-1)

`clevis luks list -d /dev/sda1` then shows one entry per pin/slot (`1: sss …`, `2: tang …`,
`3: tpm2 …`), confirming that binding accumulates independent keyslots/slots rather than
replacing one. <https://manpages.debian.org/trixie/clevis-luks/clevis-luks-list.1.en.html>

**Answer.** Yes: LUKS2 supports many keyslots, and `clevis luks bind` adds a keyslot (and, on
LUKS2, a token) for a `tang`/`tpm2` pin without re-encrypting the volume. The master/volume key
is unchanged, so a passphrase added now and a Clevis binding added later coexist.

---

## 9. Must the volume be LUKS2 to add Clevis TPM2/Tang later?

**Verdict: UNVERIFIED as stated — the primary sources contradict the requirement.** Clevis
supports **both LUKS1 and LUKS2**; `tpm2` and `tang` pins can be added to a LUKS1 volume later
without re-encrypting it. LUKS2 is still the right choice, but not for the stated reason.

**Evidence that clevis supports LUKS1**

- `clevis-luks-bind(1)` documents both storage paths in one command: `-s SLT` is *"The LUKSMeta
  slot to use for metadata storage"* (LUKS1), while `-t TKN_ID` is *"The LUKS token ID to use;
  **only available for LUKS2**"*. <https://manpages.debian.org/trixie/clevis-luks/clevis-luks-bind.1.en.html>
- The upstream bind script explicitly branches on the detected type; for LUKS1 it initialises
  LUKSMeta and refuses only the LUKS2-only option:

  ```
  if [ "${luks_type}" = "luks1" ] && [ -n "${TOKEN_ID}" ]; then
      echo "${DEV} is a LUKS1 device; -t is only supported in LUKS2" >&2
  ...
  if [ "${luks_type}" = "luks1" ] && ! luksmeta test -d "${DEV}"; then
      luksmeta init -d "${DEV}" ${FRC}
  ```

  <https://raw.githubusercontent.com/latchset/clevis/master/src/luks/clevis-luks-bind>
- The clevis README describes the mechanism generically (LUKSMeta is the LUKS1 metadata area):
  *"We generate a new, cryptographically strong key. This key is added to LUKS as an additional
  passphrase. We then encrypt this key using Clevis, and store the output JWE inside the LUKS
  header using LUKSMeta."* <https://raw.githubusercontent.com/latchset/clevis/master/README.md>
- Debian packaging: `clevis` Depends on `luksmeta`; `clevis-luks` Depends on `cryptsetup-bin`,
  `jq`, `luksmeta`; `clevis-tpm2` Depends on `clevis` and `tpm2-tools`. The LUKSMeta dependency
  exists precisely for the LUKS1 path.
  <https://sources.debian.org/src/clevis/20-1/debian/control/>

**What is true about LUKS2 (use these reasons instead)**

- `cryptsetup luksFormat` defaults to LUKS2: *"To enforce a specific version of LUKS format, use
  --type luks1 or --type luks2. **The default format is LUKS2.**"*
  <https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/man/cryptsetup-luksFormat.8.adoc>
- Capacity: LUKS2 has 32 keyslots vs LUKS1's 8 (`LUKS2_KEYSLOTS_MAX` vs `LUKS_NUMKEYS`, above).
  This is the real argument for LUKS2 if several pins/passphrases will accumulate.
- LUKS2 stores clevis configuration natively as LUKS2 tokens (`-t TKN_ID`), and supports
  per-keyslot PBKDF/Argon2; LUKS1 uses the separate LUKSMeta header and a single PBKDF/hash for
  all keyslots.
- LUKS1 → LUKS2 conversion exists but is conditional: `cryptsetup convert --type luks2 <device>`
  *"Converts the device between LUKS1 and LUKS2 format (if possible). The conversion will not be
  performed if there is an additional LUKS2 feature or LUKS1 has an unsupported header size. ...
  Conversion (both directions) must be performed on an inactive device."*
  <https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/man/cryptsetup-convert.8.adoc>
- If the design later wants **`systemd-cryptenroll` TPM2** (instead of Clevis), that path does
  require LUKS2. That is a systemd/cryptsetup requirement, not a Clevis one.

**Recommendation.** Create the volumes as LUKS2 (`cryptsetup luksFormat --type luks2`, which is
the default) for the capacity/token/default reasons above — but do not document the requirement
as "Clevis cannot add TPM2/Tang to LUKS1", because that is not what the primary sources say.
Also do the initial `clevis luks bind` promptly if the 8-slot LUKS1 ceiling is a concern, or
convert before adding bindings.

---

## 10. Does Debian's `clevis-initramfs` support initramfs-tools (not just dracut)?

**Verdict: CONFIRMED — it is an initramfs-tools integration; dracut is a separate package.**

**Debian package, trixie (`clevis-initramfs` 20-1):**

> *"Clevis is a plugable framework for automated decryption. **This package provides integration
> for initramfs-tools** to automatically unlock LUKS encrypted block devices in early boot."*

> *"dep: clevis-luks; dep: **initramfs-tools** — generic modular initramfs generator (automation)"*

<https://packages.debian.org/trixie/clevis-initramfs>

**Installed files are the initramfs-tools hook/script triple** (not dracut modules):

```
/usr/share/initramfs-tools/hooks/clevis
/usr/share/initramfs-tools/scripts/local-top/clevis
/usr/share/initramfs-tools/scripts/local-bottom/clevis
/usr/share/doc/clevis-initramfs/README.Debian
```

<https://packages.debian.org/trixie/all/clevis-initramfs/filelist>

The Debian source `control` confirms the same dependencies: `clevis-initramfs` Depends on
`clevis-luks` and `initramfs-tools`; `clevis-dracut` is the separate dracut package and depends
on `dracut`/`dracut-network`. <https://sources.debian.org/src/clevis/20-1/debian/control/>

**Upstream README** documents the initramfs-tools unlocker side by side with dracut:

> *"Unlocker: Initramfs-tools — When using Clevis with initramfs-tools, in order to rebuild your
> initramfs you will need to run: `sudo update-initramfs -u -k 'all'`."*

<https://raw.githubusercontent.com/latchset/clevis/master/README.md>

**Debian-specific note** (`clevis-initramfs.README.Debian`): if not all devices are unlocked
automatically, add the `initramfs` option to the relevant `/etc/crypttab` line and re-run
`update-initramfs`:

> *"In some circumstances, clevis(-initramfs) will not unlock all devices needed for boot. In
> that case, consider adding the 'initramfs' option to /etc/crypttab for any device that is not
> handled automatically. (And don't forget to run update-initramfs afterwards.)"*

<https://sources.debian.org/src/clevis/20-1/debian/clevis-initramfs.README.Debian/>

The upstream unlocker overview also lists which unlockers exist (`clevis-luks-unlock` manual,
`dracut`, `systemd`, `udisks2`) and states that early-boot integration is for the **root** volume
only: <https://manpages.debian.org/trixie/clevis-luks/clevis-luks-unlockers.7.en.html>.

---

## 11. Debian `dropbear-initramfs`: LUKS2 root, network config, host keys, unattended reboot

**Verdict: CONFIRMED for the SSH-unlock workflow; the LUKS2-specific wording is supported only
indirectly (see below).**

### 11a. Does it unlock a LUKS2 root?

dropbear itself is LUKS-agnostic — it only provides an SSH server in the initramfs. The actual
unlock is performed by the cryptsetup initramfs tooling, which the package recommends:

- `dropbear-initramfs` Depends: `busybox`, `dropbear-bin`, `initramfs-tools`, `udev`;
  **Recommends: `cryptsetup-initramfs`** (trixie).
  <https://packages.debian.org/trixie/dropbear-initramfs>
- `README.initramfs`: *"You can unlock your rootfs on bootup remotely, using SSH to log in to
  the booting system while it's running with the initramfs mounted. Consult cryptsetup's
  /usr/share/doc/cryptsetup/README.Debian.gz sec. 8 for details."*
  <https://sources.debian.org/src/dropbear/2025.89-1~deb13u1/debian/README.initramfs/>
- OpenZFS Debian Trixie guide, LUKS install: dropbear is installed, `/etc/dropbear/initramfs/`
  is populated, and *"For LUKS, run `cryptroot-unlock`."*
  <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

`cryptroot-unlock` is the cryptsetup-initramfs tool and handles the modern default LUKS2 header;
trixie's cryptsetup is LUKS2-capable (`cryptsetup luksFormat` defaults to LUKS2, §9). The narrow
sentence "cryptroot-unlock supports LUKS2 root" is **UNVERIFIED** as an explicit documentation
statement — no fetched primary source states it in those words — but the workflow (dropbear SSH
+ `cryptroot-unlock`) is the one the OpenZFS LUKS guide prescribes, and LUKS2 is the default
format in trixie.

### 11b. How is the initramfs network configured?

The dropbear `init-premount` script always brings the network up (in the background on local
boots, awaited on NFS) before starting the daemon:

```
# always run configure_networking() before dropbear(8); on NFS
# mounts this has been done already
[ "$BOOT" = nfs ] || configure_networking
...
exec /sbin/dropbear -$flags ${DROPBEAR_OPTIONS-}
```

Source: <https://sources.debian.org/src/dropbear/2025.89-1~deb13u1/debian/initramfs/scripts/init-premount/dropbear/>

`configure_networking()` is initramfs-tools' function; it reads the `$IP` variable and selects
the device in this precedence order: **1.** the device in the `ip=` parameter, **2.** `BOOTIF=`,
**3.** the build-time `DEVICE` variable. Then:

```
case "${IP-}" in
none|off)          # Do nothing
""|on|any)         ipconfig -t ${ROUNDTTT} "${DEVICE}"          # DHCP-ish
dhcp|bootp|rarp|both) ipconfig -t ${ROUNDTTT} -c "${IP}" -d "${DEVICE}"
*)                 ipconfig -t ${ROUNDTTT} -d "$IP"             # static
esac
```

Source: <https://sources.debian.org/src/initramfs-tools/0.148.4/scripts/functions/>

- **Default = DHCP.** With `$IP` unset, `configure_networking()` runs `ipconfig` against the
  first usable device. The `init-premount` comment warns: *"With the default ip=dhcp,
  configure_networking hangs for 5mins or so when the network is unavailable."*
- **Static IP / choosing the device: the `ip=` kernel boot parameter.** `README.initramfs`:
  *"Set the 'ip=' kernel boot parameter if you wish to use a non-default IP address or device.
  ... If 'ip=none' or 'ip=off', then dropbear is not started at boot time."*
  `initramfs-tools(7)` documents `ip` as *"tells how to configure the ip address"* (it also notes
  it is the documented optional parameter for NFS root).
  <https://manpages.debian.org/trixie/initramfs-tools-core/initramfs-tools.7.en.html>
- **Static IP via build-time config.** The OpenZFS Trixie guide documents putting it in
  `/etc/initramfs-tools/initramfs.conf`, syntax `IP=ADDRESS::GATEWAY:MASK:HOSTNAME:NIC`
  (HOSTNAME and NIC optional), followed by `update-initramfs -u -k all`. `initramfs.conf(5)`
  documents the file and the `conf.d` override mechanism, but does **not** list an `IP=`
  variable for local boot — the `IP` value is consumed by `configure_networking()` at boot
  (`IP_` is the exported `ip` boot-option). Use `ip=` on the kernel command line as the
  canonical/documented route; `IP=` in `/etc/initramfs-tools/initramfs.conf` (or a
  `/etc/initramfs-tools/conf.d/` snippet) works but is not documented in `initramfs.conf(5)`.
  <https://manpages.debian.org/trixie/initramfs-tools-core/initramfs.conf.5.en.html>
- **NIC driver.** `README.initramfs`: *"You'll have to include the driver of (one of) your
  network card(s) to /etc/initramfs-tools/modules."* Then `update-initramfs -u -k all`.
- Other options live in `/etc/dropbear/initramfs/dropbear.conf` via `DROPBEAR_OPTIONS`
  (e.g. `-p 2222`); password logins are disabled and authorized keys are read from
  `/etc/dropbear/initramfs/authorized_keys`.

### 11c. Where do the SSH host keys come from, and can they be regenerated per machine?

`README.initramfs` (dropbear-initramfs 2025.89-1~deb13u1):

> *"The host keys used for the initramfs are dropbear_{rsa,ecdsa,ed25519}_host_key, all four
> located in the /etc/dropbear/initramfs directory. They are created automatically if they do
> not exist when dropbear-initramfs is installed or upgraded. They can also be created manually
> with the following commands: `dropbearkey -t rsa -f /etc/dropbear/initramfs/dropbear_rsa_host_key`
> ... A warning is raised if none of these host key files exist. (dropbear will then fail to
> start.) **In case of an encrypted rootfs, you typically don't want the initramfs SSHd to reuse
> the host keys of the main SSH server (those in /etc/ssh or /etc/dropbear), since the initrd
> lies in /boot which, unlike /etc, is usually not encrypted.**"*

<https://sources.debian.org/src/dropbear/2025.89-1~deb13u1/debian/README.initramfs/>

This default (distinct initramfs-only keys) has been the behaviour since 2015.68-1; the Debian
maintainer confirmed it in bug #1067154 and gave the regeneration recipe:

> *"New host keys are generated at postinst stage, and used for initramfs only. But not when
> upgrading of course, as this would break pinned key material."*
> *"I believe removing /etc/dropbear/initramfs/dropbear_*_host_key and running
> `dpkg-reconfigure dropbear-initramfs` will generate new keys for initramfs use."*

<https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1067154>

So for per-machine identity hygiene: allow the postinst-generated per-host keys (do not copy a
golden image's `/etc/dropbear/initramfs/*` keys into new machines), or delete the key files and
run `dpkg-reconfigure dropbear-initramfs` on each machine. Notes:

- **Caveat about copying OpenSSH keys.** The OpenZFS Trixie guide offers `dropbearconvert` to
  make dropbear use the *same* keys as the main OpenSSH server; the guide itself flags the
  downside: *"the OpenSSH keys are then available on-disk, unencrypted in the initramfs."*
  Prefer the default distinct initramfs keys for identity hygiene.
- **Transient keys.** `DROPBEAR_OPTIONS="-R"` makes dropbear generate host keys at boot time
  (per machine, not pinnable in `known_hosts`); the maintainer notes this in the same bug.
- Clients will see a host-key mismatch warning if the initramfs and main SSH server use
  different keys; `README.initramfs` suggests a separate port and/or `UserKnownHostsFile`
  (e.g. `~/.luks/known_hosts`).

### 11d. Operational consequence: unattended reboot needs a human

**CONFIRMED.** With a LUKS-encrypted root and no Clevis/TPM2/keyfile auto-unlock, the boot stops
in the initramfs waiting for the passphrase; dropbear is the out-of-band way in:

1. The machine boots the unencrypted ext4 `/boot` (this is the design's premise — kernel +
   initramfs are available before any unlock).
2. initramfs-tools configures the network and starts dropbear.
3. A human SSHs in as root (public-key only) and runs **`cryptroot-unlock`** for LUKS (or
   `zfsunlock` for ZFS native encryption) and supplies the passphrase.
4. The root pool is imported and the boot continues.

Sources: dropbear `README.initramfs` (unlock by SSH during initramfs) and the OpenZFS Debian
Trixie guide: *"Earlier, to use this functionality, SSH to the system (as root) while it is
prompting for the passphrase during the boot process. ... For LUKS, run `cryptroot-unlock`."*
<https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

Because `/etc/dropbear/initramfs/authorized_keys` (and the host keys) live in `/boot`/initramfs
unencrypted, treat them as exposed: they are the credentials that gate a physical-disk unlock.
Auto-unlock (Clevis/Tang/TPM2, or a keyfile) removes the human-in-the-loop requirement and
should be designed as a separate, deliberate step — matching the "dropbear now, Clevis/TPM2/Tang
later" migration plan.

---

## Design-level conclusions

1. **GRUB is the correct choice** for both UEFI and legacy BIOS, and it is the only array-aware
   option among the loaders considered: it parses mdadm 0.90/1.0/1.1/1.2 and RAID levels
   0/1/4/5/6/10 directly from member devices. syslinux does not parse md metadata and offers
   only a manual per-member mirror procedure, which upstream never completed for metadata 1.2.
2. **BIOS+GPT needs an EF02 BIOS Boot Partition** (≥31 KiB, recommend ~1 MiB; OpenZFS guide uses
   1000 KiB starting at 24K) and `grub-install /dev/<disk>` (whole disk).
3. **UEFI needs a per-disk FAT ESP** (never an md array — firmware cannot read md), while
   `/boot` may be mdadm RAID1 because GRUB, not firmware, reads it; `grub-install` embeds the
   mdraid module.
4. **`/boot` on mdadm RAID1 requires the `mdadm` package** so initramfs-tools can assemble
   arrays (hooks/scripts + mdadm.conf) for anything needed before `switch_root`; keep
   `mdadm.conf` current and rebuild the initramfs.
5. **Set `-o compatibility=<profile>` at pool creation** and never `zpool upgrade` past it.
   The property persists and constrains `zpool upgrade`; narrowing it later does not remove
   already-enabled features, and only `legacy` is documented to block manual
   `zpool set feature@…=enabled`.
6. **LUKS2 is recommended but the Clevis LUKS2-requirement premise is wrong.** Clevis supports
   LUKS1 via LUKSMeta and adds TPM2/Tang keyslots without re-encryption on both formats. Choose
   LUKS2 at creation anyway (default, 32 keyslots, native tokens, systemd-cryptenroll
   compatibility).
7. **`clevis-initramfs` is a first-class initramfs-tools integration** (Depends:
   `initramfs-tools`; hook + local-top + local-bottom scripts); build with
   `update-initramfs -u -k all`.
8. **`dropbear-initramfs` gives the out-of-band unlock path** with per-host, initramfs-only host
   keys (regenerate with `dpkg-reconfigure dropbear-initramfs` after deleting the key files),
   network via `ip=` (or `IP=` in `initramfs.conf`/`conf.d`), and a mandatory human
   `cryptroot-unlock` on every unattended reboot until Clevis/TPM2 is added.

---

## Source index (all primary)

**GRUB**

- GNU GRUB Manual 2.14 — BIOS installation (MBR, GPT, BIOS Boot Partition, EF02, size) —
  <https://www.gnu.org/software/grub/manual/grub/html_node/BIOS-installation.html>
- GNU GRUB Manual 2.14 — Installation (image directory vs boot directory) —
  <https://www.gnu.org/software/grub/manual/grub/html_node/Installation.html>
- GNU GRUB Manual 2.14 — Installing GRUB using grub-install —
  <https://www.gnu.org/software/grub/manual/grub/html_node/Installing-GRUB-using-grub_002dinstall.html>
- GNU GRUB Manual 2.14 — Invoking grub-install (`--efi-directory`, `--boot-directory`, install device) —
  <https://www.gnu.org/software/grub/manual/grub/html_node/Invoking-grub_002dinstall.html>
- GRUB source `grub-core/disk/mdraid1x_linux.c` (metadata 1.0/1.1/1.2; levels) —
  <https://cgit.git.savannah.gnu.org/cgit/grub.git/plain/grub-core/disk/mdraid1x_linux.c>
- GRUB source `grub-core/disk/mdraid_linux.c` (metadata 0.90; levels) —
  <https://cgit.git.savannah.gnu.org/cgit/grub.git/plain/grub-core/disk/mdraid_linux.c>
- Debian wiki — Grub — <https://wiki.debian.org/Grub>
- Debian wiki — GrubEFIReinstall (ESP + separate /boot layout; grubx64.efi path) —
  <https://wiki.debian.org/GrubEFIReinstall>
- Debian wiki — SoftwareRAID (mdadm + initramfs regeneration) —
  <https://wiki.debian.org/SoftwareRAID>
- OpenZFS — Debian Trixie Root on ZFS (EF02 partition, `grub-install $DISK`, UEFI install, LUKS,
  dropbear) —
  <https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html>

**syslinux**

- Syslinux Wiki — EXTLINUX (RAID-1 procedure; filesystem bootloader) —
  <https://wiki.syslinux.org/wiki/index.php?title=EXTLINUX>
- Syslinux Wiki — Doc/extlinux (same, release 3.72 text) —
  <https://wiki.syslinux.org/wiki/index.php?title=Doc/extlinux>
- Syslinux Wiki — Doc/syslinux (`-r` Raid mode definition) —
  <https://wiki.syslinux.org/wiki/index.php?title=Doc/syslinux>
- Syslinux Wiki — Development/LVM support (pointer to the RAID 1.2 superblock thread) —
  <https://wiki.syslinux.org/wiki/index.php?title=Development/LVM_support>
- syslinux mailing list, 2010-06-11 — "Linux software RAID 1.2 superblocks" (question) —
  <https://www.syslinux.org/archives/2010-June/014813.html>
- syslinux mailing list, 2010-06-11 — H. Peter Anvin reply ("I haven't written that code") —
  <https://www.syslinux.org/archives/2010-June/014815.html>
- syslinux source tree `core/` (no md/mdraid metadata driver) —
  <https://kernel.googlesource.com/pub/scm/boot/syslinux/syslinux/+/refs/heads/master/core/>

**Debian initramfs-tools / mdadm**

- Debian package file list — mdadm (trixie) —
  <https://packages.debian.org/trixie/amd64/mdadm/filelist>
- mdadm Debian source, `debian/mdadm.initramfs-hook` (initramfs hook) —
  <https://sources.debian.org/src/mdadm/4.4-11/debian/mdadm.initramfs-hook/>
- mdadm.conf(5), trixie —
  <https://manpages.debian.org/trixie/mdadm/mdadm.conf.5.en.html>
- initramfs-tools(7), trixie (hook/boot script model, local-block) —
  <https://manpages.debian.org/trixie/initramfs-tools-core/initramfs-tools.7.en.html>
- initramfs.conf(5), trixie (conf.d override; no documented local-boot `IP=`) —
  <https://manpages.debian.org/trixie/initramfs-tools-core/initramfs.conf.5.en.html>

**OpenZFS**

- zpoolprops(7) — `compatibility` property and persistence —
  <https://openzfs.github.io/openzfs-docs/man/master/7/zpoolprops.7.html>
- zpool-features(7) — Compatibility feature sets; feature states ("cannot be disabled once
  enabled") —
  <https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html>
- zpool-upgrade(8) — upgrade constrained by compatibility —
  <https://openzfs.github.io/openzfs-docs/man/master/8/zpool-upgrade.8.html>
- zpool-create(8) — `-o compatibility=` at creation —
  <https://openzfs.github.io/openzfs-docs/man/master/8/zpool-create.8.html>
- zpool-set(8) — `zpool set property=value pool` —
  <https://openzfs.github.io/openzfs-docs/man/master/8/zpool-set.8.html>
- OpenZFS issue #12261 — compatibility lost on hard-force export (fixed by PR #12276) —
  <https://github.com/openzfs/zfs/issues/12261>
- OpenZFS commit 17a2b35 — compatibility.d files; adds `openzfs-2.3` under
  `cmd/zpool/compatibility.d/` —
  <https://github.com/openzfs/zfs/commit/17a2b35be577db50c19f3c1bd8f64e69abdc085b>

**LUKS / Clevis**

- cryptsetup(8) — LUKS keyslots; default format is LUKS2 —
  <https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/man/cryptsetup.8.adoc>
- cryptsetup-luksFormat(8) — default format LUKS2; `--type` —
  <https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/man/cryptsetup-luksFormat.8.adoc>
- cryptsetup-luksAddKey(8) — adds a keyslot; LUKS2 token options —
  <https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/man/cryptsetup-luksAddKey.8.adoc>
- cryptsetup-convert(8) — LUKS1 ↔ LUKS2 conversion conditions —
  <https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/man/cryptsetup-convert.8.adoc>
- cryptsetup source `lib/luks2/luks2.h` — `LUKS2_KEYSLOTS_MAX 32`, `LUKS2_TOKENS_MAX 32` —
  <https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/lib/luks2/luks2.h>
- cryptsetup source `lib/luks1/luks.h` — `LUKS_NUMKEYS 8` —
  <https://gitlab.com/cryptsetup/cryptsetup/-/raw/main/lib/luks1/luks.h>
- clevis-luks-bind(1), trixie — four steps; adds key; does not change master key; LUKS2-only
  `-t` —
  <https://manpages.debian.org/trixie/clevis-luks/clevis-luks-bind.1.en.html>
- clevis-luks-list(1), trixie — one entry per bound pin/slot —
  <https://manpages.debian.org/trixie/clevis-luks/clevis-luks-list.1.en.html>
- clevis-luks-unlockers(7), trixie — unlocker overview; early boot is root-volume only —
  <https://manpages.debian.org/trixie/clevis-luks/clevis-luks-unlockers.7.en.html>
- Clevis upstream README — binding mechanism (LUKSMeta; `clevis luks bind`) and initramfs-tools
  unlocker —
  <https://raw.githubusercontent.com/latchset/clevis/master/README.md>
- Clevis upstream `src/luks/clevis-luks-bind` — LUKS1/LUKS2 branching, `luksmeta init` —
  <https://raw.githubusercontent.com/latchset/clevis/master/src/luks/clevis-luks-bind>
- Debian package — clevis-initramfs (trixie) —
  <https://packages.debian.org/trixie/clevis-initramfs>
- Debian file list — clevis-initramfs (trixie) —
  <https://packages.debian.org/trixie/all/clevis-initramfs/filelist>
- Clevis Debian source, `debian/control` — package dependencies (luksmeta, tpm2-tools,
  initramfs-tools) —
  <https://sources.debian.org/src/clevis/20-1/debian/control/>
- Clevis Debian source, `debian/clevis-initramfs.README.Debian` — `initramfs` crypttab option —
  <https://sources.debian.org/src/clevis/20-1/debian/clevis-initramfs.README.Debian/>

**dropbear-initramfs**

- Debian package — dropbear-initramfs (trixie) — Recommends cryptsetup-initramfs —
  <https://packages.debian.org/trixie/dropbear-initramfs>
- Debian file list — dropbear-initramfs (trixie) —
  <https://packages.debian.org/trixie/all/dropbear-initramfs/filelist>
- `README.initramfs`, dropbear 2025.89-1~deb13u1 — host keys, `ip=`, authorized_keys, unlock
  procedure —
  <https://sources.debian.org/src/dropbear/2025.89-1~deb13u1/debian/README.initramfs/>
- dropbear initramfs `scripts/init-premount/dropbear` — calls `configure_networking`, starts
  dropbear —
  <https://sources.debian.org/src/dropbear/2025.89-1~deb13u1/debian/initramfs/scripts/init-premount/dropbear/>
- initramfs-tools `scripts/functions` — `configure_networking()` / `$IP` handling —
  <https://sources.debian.org/src/initramfs-tools/0.148.4/scripts/functions/>
- Debian bug #1067154 — initramfs host keys generated at postinst; regeneration command —
  <https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1067154>

**OpenZFS manpage version note.** All `openzfs.github.io/openzfs-docs/man/master/...` links have
matching `v2.3` versions (e.g. `.../man/v2.3/7/zpoolprops.7.html`) that correspond to the
OpenZFS release shipped in trixie; `master` was used for the current upstream text.
