# Live-environment notes for Debian 13 (trixie) root-on-ZFS provisioning

Primary-source verification, dated **2026-09-17**. Scope: the live/netboot environment used to
provision Debian 13 "trixie" root-on-ZFS machines (mobile, PXE-capable, no persistent caches,
USB carried), with Ubuntu 26.04.1 live-server as the currently-preferred host environment.

Method: every factual claim below is tied to the source that owns it (distribution ISO manifests
and file listings, package archive indexes, upstream man pages, the Debian Live Manual, Debian
bug/changelog records). Items that could not be confirmed against a primary source are explicitly
marked **UNVERIFIED**. No package lists, versions, or URLs were invented.

> Note on the two ZFS stacks involved: Debian 13 ships ZFS as **DKMS source in `contrib`**
> (zfs-linux 2.3.9), whereas Ubuntu 26.04 ships ZFS as a **prebuilt kernel module package**
> (`linux-modules-zfs-*`) plus userspace from `main` (zfs-linux 2.4.1). This difference drives
> most of the answers below.

---

## Q1 — Ubuntu 26.04.1 live-server: ZFS kernel module present, `zfsutils-linux` absent

**CONFIRMED.** The Ubuntu 26.04.1 LTS ("Resolute Raccoon") live-server ISO ships the ZFS *kernel
module* package but **not** `zfsutils-linux` (hence no `/usr/sbin/zpool` or `/usr/sbin/zfs`).

Sources (all Canonical/Ubuntu):
- Release directory: <https://releases.ubuntu.com/26.04.1/> (live-server filename
  `ubuntu-26.04.1-live-server-amd64.iso`, dated 2026-08-26; 26.04 GA was 2026-04-23).
- Live-filesystem package manifest (official): <https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-live-server-amd64.manifest>
- ISO file listing (official): <https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-live-server-amd64.list>

Grep results I obtained:

| Question | Result in `.manifest` (installed in live filesystem) | Result in `.list` (ISO contents) |
|---|---|---|
| ZFS kernel module | `linux-main-modules-zfs-7.0.0-30-generic  7.0.0-30.30` (line 465) | `/pool/main/l/linux-main-signed/linux-main-modules-zfs-7.0.0-30-generic_7.0.0-30.30_amd64.deb` |
| `zfsutils-linux` | **absent** | present only as a pool `.deb` (see Q2) |
| `libzfs7linux`, `libzpool7linux`, `libnvpair3linux`, `libuutil3linux` | **absent** | present only as pool `.deb`s |
| `zfs-zed`, `zfs-dracut`, `zfs-initramfs`, `zfs-dkms` | **absent** | `zfs-zed` and `zfs-dracut` present as pool `.deb`s; `zfs-dkms`/`zfs-initramfs` not present |
| `debootstrap` | **absent** | **absent** |
| `mmdebstrap` | **absent** | **absent** |
| `dpkg-dev` | **absent** | **absent** |
| `dpkg` | `dpkg 1.23.7ubuntu1` | — |
| `apt` | `apt 3.2.0` | — |

Also relevant:
- Kernel in the live image is **7.0.0-30-generic**; the manifest also contains
  `linux-headers-generic 7.0.0-30.30` and `linux-headers-7.0.0-30-generic` (headers *are* present
  — see Q3/Q7). GRUB's own ZFS modules are on the ISO (`/boot/grub/x86_64-efi/zfs.mod`, etc.).
- Contrast: the **desktop** ISO *does* ship the userspace tools —
  `ubuntu-26.04.1-desktop-amd64.manifest` contains `zfsutils-linux  2.4.1-1ubuntu5`,
  `libzfs7linux:amd64  2.4.1-1ubuntu5`, `zfs-zed  2.4.1-1ubuntu5`. The server flavour does not.
- Ubuntu 26.04 does **not** use DKMS for ZFS at all. In the `resolute` `main` archive there is no
  `zfs-dkms` package; instead there are prebuilt module packages
  (`linux-modules-zfs-generic`, `linux-main-modules-zfs-<ver>-<flavour>`). Source:
  <http://archive.ubuntu.com/ubuntu/dists/resolute/main/binary-amd64/Packages.gz>.

**Consequence for the team:** booting Ubuntu 26.04 live gives you the `zfs.ko` module but *not*
the `zpool`/`zfs` userspace binaries. So the live environment as shipped cannot create/import a
pool until the userspace `.deb`s are installed (Q2/Q3).

---

## Q2 — The `zfsutils-linux` `.deb` is in the ISO pool; Ubuntu ships OpenZFS 2.4.1

**CONFIRMED for the `.deb` presence and the version.**

From the official ISO file listing
(<https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-live-server-amd64.list>), the pool contains
(all at version `2.4.1-1ubuntu5`):

```
/pool/main/z/zfs-linux/libnvpair3linux_2.4.1-1ubuntu5_amd64.deb
/pool/main/z/zfs-linux/libuutil3linux_2.4.1-1ubuntu5_amd64.deb
/pool/main/z/zfs-linux/libzfs7linux_2.4.1-1ubuntu5_amd64.deb
/pool/main/z/zfs-linux/libzpool7linux_2.4.1-1ubuntu5_amd64.deb
/pool/main/z/zfs-linux/zfsutils-linux_2.4.1-1ubuntu5_amd64.deb
/pool/main/z/zfs-linux/zfs-dracut_2.4.1-1ubuntu5_all.deb
/pool/main/z/zfs-linux/zfs-zed_2.4.1-1ubuntu5_amd64.deb
```

So yes — the `zfsutils-linux` `.deb` and all four libraries it depends on are present in the ISO's
package pool, so they can in principle be installed offline.

**ZFS version.** Ubuntu 26.04 (resolute) ships **OpenZFS 2.4.1**.
- The ISO's pool `.deb`s are `2.4.1-1ubuntu5` (above).
- Launchpad publishing history confirms the release pocket version `2.4.1-1ubuntu5` (published
  2026-04-15) and that `2.4.1-1ubuntu5.1` was later published to `resolute-security`/`-updates`
  on 2026-08-31: <https://launchpad.net/ubuntu/resolute/amd64/zfsutils-linux>.
- The `resolute` `main` archive `Packages` stanza for `zfsutils-linux` states
  `Version: 2.4.1-1ubuntu5`, `Section: admin`, `Source: zfs-linux`, and
  `Depends: libnvpair3linux (= 2.4.1-1ubuntu5), libuutil3linux (= 2.4.1-1ubuntu5),
  libzfs7linux (= 2.4.1-1ubuntu5), libzpool7linux (= 2.4.1-1ubuntu5), python3, gawk,
  libblkid1 (>= 2.16), libc6 (>= 2.38), libssl3t64 (>= 3.0.0), libudev1 (>= 183),
  libuuid1 (>= 2.16)` (also `Recommends: zfs-zed`).
  Source: <http://archive.ubuntu.com/ubuntu/dists/resolute/main/binary-amd64/Packages.gz>.

**UNVERIFIED:** whether the ISO's *embedded* `dists/resolute/main/binary-amd64/Packages` index
actually lists `zfsutils-linux`. The index file itself is present on the ISO (it appears in the
`.list`: `/dists/resolute/Release`, `/dists/resolute/Release.gpg`,
`/dists/resolute/main/binary-amd64/Packages{,.gz}`, plus `restricted`), and `zfsutils-linux` is in
Ubuntu component `main` per Launchpad, so it is very likely indexed — but reading the index would
require downloading the 2.7 GB ISO, which was not done. The `.deb` presence itself is confirmed.

---

## Q3 — Offline `.deb` install in the Ubuntu live-server environment

**YES, with documented caveats.** Three mechanisms exist; only one is fully offline-safe.

1. **Configure the mounted ISO/USB pool as an APT source, then `apt-get install` (recommended,
   fully offline).** The ISO carries `dists/resolute/Release`, `Release.gpg` and
   `main`/`restricted` `Packages` indexes alongside `pool/` (confirmed in the `.list`). Point a
   `file://` source at the mount, run `apt-get update` (local files only), then
   `apt-get install zfsutils-linux`; APT resolves the exact-version library dependencies using the
   ISO's own index. This is the only mechanism that resolves the `= 2.4.1-1ubuntu5` pins
   automatically.

2. **`dpkg -i`** works but does **not** resolve dependencies. `dpkg(1)` installs the file and, if
   dependencies are unsatisfied, leaves the package unpacked/unconfigured; you must install the
   dependencies yourself. For this package the four ZFS libraries are strictly version-pinned
   (`= 2.4.1-1ubuntu5`), and on the **server** live image none of them is preinstalled (Q1). A
   working offline `dpkg -i` therefore needs all five pool `.deb`s in one invocation, e.g.
   `dpkg -i libnvpair3linux_*.deb libuutil3linux_*.deb libzfs7linux_*.deb libzpool7linux_*.deb
   zfsutils-linux_*.deb`. `python3`, `gawk`, `libc6`, `libssl3t64`, `libudev1`, `libuuid1`,
   `libblkid1` are already in the live manifest, so those deps are satisfied. Source:
   <https://manpages.debian.org/trixie/dpkg/dpkg.1.en.html> (`-i, --install`).
   The `.list` shows the exact `.deb` filenames and the flat `pool/` layout, so no index is needed
   for this path.

3. **`apt-get install --no-download`** — documented but **not** a way to read the ISO pool.
   `apt-get(8)`: *"`--no-download` — Disables downloading of packages. This is best used with
   `--ignore-missing` to force APT to use only the .debs it has already downloaded.
   Configuration Item: `APT::Get::Download`."* I.e. it constrains APT to packages already in the
   local cache / configured sources; it does not add the ISO pool. Source:
   <https://manpages.debian.org/trixie/apt/apt-get.8.en.html>.

**Documented caveat to flag:** the Ubuntu live-server ISO's apt indexes are a *snapshot* of the
release pocket, and the live environment may also have network sources configured; mixing the
ISO's `2.4.1-1ubuntu5` with the archive's current `2.4.1-1ubuntu5.1` (published 2026-08-31) will
produce version conflicts because `zfsutils-linux` pins its libraries with `=`. Keep the whole set
from one source. Also note the live image does include `linux-headers-generic` (useful if you did
want to build something), though Ubuntu's ZFS is not DKMS-based.

**Alternate artifact worth noting:** Ubuntu also publishes
`ubuntu-26.04.1-netboot-amd64.tar.gz` (112 MB) in the same directory for network installs
(<https://releases.ubuntu.com/26.04.1/>). This was not inspected for ZFS contents.

---

## Q4 — Official Debian 13 live images do **not** include ZFS

**CONFIRMED — no ZFS at all** (neither `zfsutils-linux` nor `zfs-dkms`), because the official live
images are built from archive areas `main non-free-firmware` only, and Debian's ZFS lives in
`contrib`.

Sources:
- Debian live download page: <https://www.debian.org/CD/live/> (current images are
  `debian-live-13.7.0-amd64-*.iso`).
- Live image artifacts + build logs: <https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/>
  (each ISO has a `.packages`, `.contents`, `.log`).
- Package archive: `contrib` index
  `http://deb.debian.org/debian/dists/trixie/contrib/binary-amd64/Packages.gz` and source index
  `.../trixie/contrib/source/Sources.gz`.
- Debian ZFS wiki: <https://wiki.debian.org/ZFS>.

Evidence:
- `debian-live-13.7.0-amd64-standard.iso.packages` (1007 lines) and
  `debian-live-13.7.0-amd64-gnome.iso.packages` (2451 lines): **zero** `zfs` matches.
  `debian-live-13.7.0-amd64-standard.iso.contents`: only `/boot/grub/x86_64-efi/zfscrypt.mod`
  (GRUB's ZFS module), no ZFS userspace/kernel files.
- The GNOME build log records the exact configuration:
  `lb config --mirror-bootstrap http://deb.debian.org/debian/ --distribution trixie ... --archive-areas main non-free-firmware ...`
  — **`contrib` is not enabled**, so no ZFS packages can be selected.
- Debian `contrib` (trixie, amd64) contains the ZFS stack:
  `zfsutils-linux contrib/admin`, `zfs-dkms contrib/kernel`, `zfs-initramfs contrib/kernel`,
  `zfs-dracut contrib/kernel`, `zfs-zed contrib/admin`, plus libraries;
  source `zfs-linux` version **`2.3.9-0+deb13u1`**, binary list includes `zfs-dkms`.
- Debian ZFS wiki (Status): ZFS *"is available from contrib archive area with the form of DKMS
  source"*; and *"The modules will be built automatically only for kernels that have the
  corresponding linux-headers package installed."*

The Debian Live Project's stated policy (§2.2.1 of the manual) is *"We will only use packages from
the Debian repository in the 'main' section"* plus `non-free-firmware` since bookworm
(<https://live-team.pages.debian.net/live-manual/html/live-manual/about-project.en.html>).

**Conclusion:** an official Debian 13 live image cannot be used to create or receive ZFS pools
without first installing packages offline. A **custom** live image is required (Q5).

---

## Q5 — Custom Debian live image with `zfsutils-linux` + `zfs-dkms` via `live-build`

**YES, feasible.** `live-build` is packaged in trixie as `live-build 1:20250505+deb13u1`
(<http://deb.debian.org/debian/dists/trixie/main/binary-amd64/Packages.gz>, package `live-build`).
The Debian Live Manual is explicit that `contrib`/`non-free` can be enabled for custom images even
though official images use `main` only.

Concrete configuration knobs (primary sources: `lb_config(1)` for trixie,
<https://manpages.debian.org/trixie/live-build/lb_config.1.en.html>, and the Debian Live Manual,
<https://live-team.pages.debian.net/live-manual/html/live-manual/>):

1. **Include packages from `contrib`** (required for ZFS):
   - `lb config --archive-areas "main contrib non-free-firmware"`
   - Manual §8.1.1: *"Within the distribution archive, archive areas are major divisions of the
     archive. In Debian, these are main, contrib and non-free. Only main contains software that is
     part of the Debian distribution, hence that is the default. One or more values may be
     specified, e.g. `$ lb config --archive-areas "main contrib non-free"`"*.
   - `lb_config(1)`: *"By default, this is set to main only. Remember to check the licenses of each
     package with respect to their redistributability in your jurisdiction when enabling contrib or
     non-free with this mechanism."*
2. **Select the packages** — put them in a package list, e.g.
   `config/package-lists/zfs.list.chroot` containing `zfsutils-linux` and `zfs-dkms` (and, as
   needed, `zfs-initramfs`). Manual §8.2.1 "Package lists". You may also add a local list under
   `config/package-lists/` (Manual §8.2.3 "Local package lists").
3. **Include non-free firmware**: `--firmware-chroot true` (default true) puts firmware in the
   live image; `--firmware-binary true` (default true) puts it in debian-installer.
   `lb_config(1)`: *"includes firmware packages in the live image. Defaults to true. Beware that
   some firmware packages are non-free and will only be included if the non-free archive area is
   included in --archive-areas"*. So keep `non-free-firmware` in `--archive-areas`.
4. **Kernel flavour / headers for DKMS**: `--linux-flavours amd64` (the default for amd64 is
   `linux-image-amd64`); `--linux-packages "linux-image linux-headers"` to also install matching
   headers. Manual §8.2.10 "Kernel flavour and version"; `lb_config(1)` `-k|--linux-flavours`.
   The Live Manual's DKMS note (see Q7) says the header selection *"can be done automatically by
   live-build"* with exactly `$ lb config --linux-packages "linux-image linux-headers"`.
5. **Embed extra files**: `config/includes.chroot/` maps to `/` in the live system (Manual §9.1.1
   "Live/chroot local includes"); `config/includes.binary/` maps to the root of the live medium
   (§9.1.2 "Binary local includes"). Chroot includes are applied after package installation.
   Hooks go in `config/hooks/live/*.chroot` (Manual §9.2.1).
6. **Hybrid ISO booting both UEFI and BIOS**:
   - `lb config --binary-image iso-hybrid`
     (`lb_config(1)`: *"By default, for images using syslinux, this is set to 'iso-hybrid' to build
     CD/DVD images that may also be used like HDD images"*).
   - `lb config --bootloaders "syslinux,grub-efi"`
     (`lb_config(1)`: *"This option supports more than one bootloader to be specified (space or
     comma separated) in order to allow for both BIOS and EFI bootloaders to be included, though
     note that only one of each type can be used"*). `syslinux` is the BIOS loader, `grub-efi` the
     UEFI one.
   - Optional Secure Boot: `--uefi-secure-boot auto|enable|disable`
     (`lb_config(1)`: auto installs signed shim/grub-efi when available, otherwise warns and uses
     unsigned grub-efi).
7. **Build**: `lb clean` then `lb build`. `lb_config(1)` warns that combining a partial `lb clean`
   with netboot changes can be insufficient (see Q6).

Manual also documents installing custom/third-party `.deb`s from
`config/packages.chroot/` (Manual §8.3.1) — an alternative if you want to pin exact ZFS `.deb`s.

**Caveat:** `--archive-areas` controls both build-time and run-time mirrors; enabling `contrib` is
what makes `zfsutils-linux`/`zfs-dkms` resolvable. Whether the module actually gets *built* into
the image at build time is Q7.

---

## Q6 — PXE-bootable custom live image **and** USB

**YES to both**, and the same build tree can produce either. Sources: Debian Live Manual
`the-basics` (<https://live-team.pages.debian.net/live-manual/html/live-manual/the-basics.en.html>),
`live-boot(7)` trixie
(<https://manpages.debian.org/trixie/live-boot-doc/live-boot.7.en.html>), and `lb_config(1)`.

- **Netboot build:** `lb config -b netboot` / `--binary-image netboot`.
  Manual §4.7.3: *"if you unpack the generated `live-image-amd64.netboot.tar` archive in the
  `/srv/debian-live` directory, you'll find the filesystem image in `live/filesystem.squashfs` and
  the kernel, initrd and pxelinux bootloader in `tftpboot/`."* So the PXE/TFTP artifacts
  (kernel + initrd + pxelinux) and the squashfs are both produced.
- **Root filesystem transport:** the manual's netboot recipe serves the squashfs over **NFS**
  (DHCP → TFTP → NFS; §4.7.1–4.7.3), and `live-boot(7)` documents `netboot[=nfs|cifs]` with
  `nfsroot=` / `nfsopts=`. **HTTP/HTTP-served squashfs is also documented**, via webbooting:
  `live-boot(7)` documents `fetch=URL` and `httpfs=URL` — *"Another form of netboot by downloading a
  squashfs image from a given URL. The fetch method copies the image to RAM and the httpfs method
  uses FUSE and httpfs2 to mount the image in place."* Manual §4.8 "Webbooting". So
  kernel+initrd over TFTP and squashfs over HTTP (`append boot=live components
  fetch=http://host/path/filesystem.squashfs`) is a documented configuration.
- **USB:** the manual §4.4.2 documents writing an ISO-hybrid image to a USB stick; `lb_config(1)`
  additionally offers `-b hdd` (HDD image) with `--binary-filesystem fat16|fat32|ext2|ext3|ext4|ntfs`.
  The manual §4.4.3 also covers using the leftover space on the USB stick.
- `--net-tarball true|false` (default true) controls whether the netboot output is a tarball or a
  plain `binary/` directory (`lb_config(1)`).

**IMPORTANT VERSION CAVEAT (verified):** the Live Manual's netboot recipe shows
`lb config -b netboot --net-root-path "/srv/debian-live" --net-root-server "192.168.0.2"`, **but
the trixie `lb_config(1)` man page does not list `--net-root-path`/`--net-root-server`**, and the
trixie `live-build` changelog records:
- `config: obsolete --net-root-path`
- `config: obsolete unused --net-cow-* options`
- `config: obsolete --net-root-* options (except one)`
(Source: <https://metadata.ftp-master.debian.org/changelogs/main/l/live-build/live-build_20250505+deb13u1_changelog>.)

So the manual's netboot section is **stale relative to trixie's live-build**. Treat the NFS-root
server/path flags as version-dependent and **UNVERIFIED** for `live-build 1:20250505+deb13u1`;
verify with `lb config --help`/`man lb_config` on the exact build host. The `-b netboot` build and
the tftpboot/squashfs outputs are still documented; the DHCP/TFTP/NFS service setup is standard
syslinux/PXE and is also documented by the Debian Installer Manual's TFTP net-boot section
(linked from the Live Manual §4.7.3):
<https://www.debian.org/releases/stable/amd64/ch04s05.en.html>.

For the team's "one operator, mobile, PXE" setup this matters: do not blindly copy the manual's
`--net-root-*` flags into a trixie build script.

---

## Q7 — Does `zfs-dkms` work in a live environment?

**Short answer:** DKMS must be built **at image-build time inside the chroot** (for the live
image's own kernel flavour); running DKMS in a *live session* to produce a module for the *target*
kernel is not documented as a supported flow and is not sensible. There is no explicit first-party
statement that "DKMS in a live session is problematic" — mark that specific phrasing **UNVERIFIED**
— but several primary facts make the runtime path clearly non-viable.

Primary evidence:
- Debian ZFS is DKMS-only in `contrib`, and *"The modules will be built automatically only for
  kernels that have the corresponding linux-headers package installed."* (<https://wiki.debian.org/ZFS>).
- The Debian Live Manual documents the build-time mechanism: for a dkms package, *"also the kernel
  headers for the kernel flavour used in your image need to be installed. Instead of manually
  listing the correct linux-headers package ..., the selection of the right package can be done
  automatically by live-build"* — `$ lb config --linux-packages "linux-image linux-headers"`
  (<https://live-team.pages.debian.net/live-manual/html/live-manual/the-basics.en.html>). This is
  the supported way to get ZFS into a custom live image.
- Missing headers is a real, reported failure mode: Debian bug #1117800 ("please add
  linux-headers-amd64 to zfs-dkms Depends") — *"dkms failed to build, because of missing linux
  headers."* (<https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1117800>). `zfs-dkms` does not
  pull headers automatically.
- The live root filesystem is a read-only squashfs overlaid for the session, so anything DKMS
  builds at runtime lands in the ephemeral overlay, is lost at reboot, and is built against the
  **running live kernel** (`uname -r`), not the kernel the target will boot.
- Kernel mismatch is the decisive issue: the live session's kernel (the flavour selected by
  `--linux-flavours`, or Ubuntu's `7.0.0-30-generic`) is a *different* package/kernel from the one
  installed onto the target root. A module built in the live session cannot satisfy the target's
  kernel; the target must build/install its own ZFS module after its kernel is installed.

Practical, documented workaround: build a **binary module `.deb`** with `dkms mkbmdeb zfs/<version>`
(the Debian ZFS wiki documents this) and carry/install that for the target kernel instead of
building in the live environment. The wiki notes the licence caveat: such packages are
*"for own use only as distributing them would infringe the licenses of both Linux and ZFS."*

For Ubuntu 26.04 specifically this is moot: Ubuntu ships a prebuilt `linux-main-modules-zfs-*`
module and no `zfs-dkms` (Q1/Q2), so the live-session DKMS question does not arise there.

---

## Q8 — `zfs send` stream as a file on a USB stick, then received on the target

Primary sources: `zfs-send(8)` <https://openzfs.github.io/openzfs-docs/man/master/8/zfs-send.8.html>
(v2.4: <https://openzfs.github.io/openzfs-docs/man/v2.4/8/zfs-send.8.html>),
`zfs-receive(8)` <https://openzfs.github.io/openzfs-docs/man/master/8/zfs-receive.8.html>,
Debian ZFS wiki <https://wiki.debian.org/ZFS>.

**File-based send/receive:**
- `zfs-send(8)`: *"Creates a stream representation of the second snapshot, which is written to
  standard output. The output can be redirected to a file or to a different system (for example,
  using `ssh(1)`)."* So sending **to a file** is documented, as output redirection — there is no
  separate "send to file" API and no dedicated OpenZFS "send/recv to file" guide.
- `zfs-receive(8)`: *"Creates a snapshot whose contents are as specified in the stream provided on
  standard input."* Receiving **from a file** is therefore `zfs receive ... < file` (stdin
  redirection). `zfs recv` is an alias.
- Resumability for a long USB transfer: `zfs-receive(8)` `-s` *"If the receive is interrupted, save
  the partially received state, rather than deleting it..."*, resumable with `zfs send -t token`
  (`receive_resume_token`). Requires the `extensible_dataset` pool feature.

**Option semantics (owner: the man pages):**
- `-R, --replicate` — replicate the filesystem and all descendants up to the named snapshot;
  properties, snapshots, descendant filesystems and clones are preserved. With `-F` on receive,
  snapshots/filesystems absent on the sender are destroyed.
- `-w, --raw` — for encrypted datasets, send data exactly as on disk (backup without loading
  keys); *"For unencrypted datasets, this flag will be equivalent to `-Lec`."*
- `-c, --compressed` — *"Generate a more compact stream by using compressed WRITE records for
  blocks which are compressed on disk and in memory."* Receive side must have the matching
  `lz4_compress`/`zstd_compress` features enabled. Streams sent with `-c` are **not** recompressed
  on the receiver.
- Raw vs non-raw receive: `zfs-receive(8)` — *"ZFS will not allow a mix of raw receives and
  non-raw receives. Specifically, any raw incremental receives that are attempted after a non-raw
  receive will fail."* Best practice: pick one.

**Compressed-stream version support (verified from upstream man pages):**
- `-c/--compressed` is present in ZFS on Linux **0.7.0** (the `zfs send` synopsis is
  `[-DnPpRveL]` in 0.6.5, with no `-c`/`-w`, and `-c, -compressed` first appears in the 0.7.0
  `zfs.8` man page; also present in 0.7.13, 0.8.0, 2.0, 2.4).
- `-w/--raw` does **not** exist in 0.7.13 and was introduced in **OpenZFS 0.8.0**: release notes
  list *"Raw encrypted 'zfs send/receive' — The `zfs send -w` option allows an encrypted dataset to
  be sent and received ... without decryption"*
  (<https://github.com/openzfs/zfs/releases/tag/zfs-0.8.0>).
- Both are present in v2.4 and v2.0 man pages
  (<https://openzfs.github.io/openzfs-docs/man/v2.4/8/zfs-send.8.html>). Debian 13 ships zfs-linux
  **2.3.9**, Ubuntu 26.04 ships **2.4.1** — both support `-c`, `-w`, `-R`, and `zfs receive -s`.

**Size/throughput considerations (what is actually documented):**
- `-c` shrinks the stream (compressed WRITE records); for unencrypted datasets `-w` = `-Lec`
  (large-block + embedded + compressed). So `-c` (or `-w`) is the documented lever for reducing
  bytes written to the USB stick.
- Progress/throughput observability is documented: `-v`/`--verbose` prints a per-second report;
  `-V`/`--proctitle` sets it as the process title; `-P`/`--parsable` prints machine-parsable
  verbose info; `-n`/`--dryrun` with `-v`/`-P` reports what *would* be sent without producing data.
- The stream is a single serial byte stream to a file/stdin; no parallel-send feature is
  documented.
- **UNVERIFIED:** there is no first-party OpenZFS numeric guidance (MB/s, USB write throughput,
  recommended chunking) for `zfs send`/`recv` via a file on removable media. Claiming specific
  throughput figures would be fabrication. The Debian wiki documents `zfs send/recv` usage
  (including `zfs send tank/data@initial | zfs recv -F tank2/packman`) but gives no throughput
  numbers.

---

## Q9 — First-party guidance on a "provisioning appliance"

**No first-party Debian guidance was found.** Debian does not appear to publish a documented
"provisioning appliance" (a portable server image providing DHCP/TFTP/HTTP for PXE) as part of its
own documentation set. This is a **NOT FOUND** result, not a claim that no third-party solution
exists.

The closest *first-party* material is procedural, not appliance-shaped:
- Debian Installer Manual, "TFTP Net Booting":
  <https://www.debian.org/releases/stable/amd64/ch04s05.en.html> (linked from the Live Manual
  §4.7.3).
- Debian Live Manual §4.7 "Building a netboot image" (DHCP/TFTP/NFS service setup):
  <https://live-team.pages.debian.net/live-manual/html/live-manual/the-basics.en.html>.

Both describe how to configure the services on an existing host; neither describes a portable,
single-operator "appliance" image. Any appliance design would have to be assembled by the team.
Do not attribute an appliance workflow to Debian.

For the team's stated setup (own network, PXE, one operator, USB), the self-consistent first-party
path is: build one custom `live-build` image that (a) boots via PXE (`-b netboot`, TFTP
kernel/initrd, squashfs via NFS or `fetch=` HTTP) and/or is written to USB (`iso-hybrid`), and
(b) contains Debian's ZFS from `contrib` — while treating the provisioning host's DHCP/TFTP/HTTP
services as ordinary `dnsmasq`/`isc-dhcp-server`/`tftpd-hpa`/HTTP configuration, not as a Debian
"appliance" product.

---

## Source index (primary)

Ubuntu / Canonical:
- <https://releases.ubuntu.com/26.04.1/> — release directory, ISO names/dates.
- <https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-live-server-amd64.manifest> — installed packages.
- <https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-live-server-amd64.list> — ISO contents / pool.
- <https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-desktop-amd64.manifest> — desktop contrast (has zfsutils-linux).
- <https://launchpad.net/ubuntu/resolute/amd64/zfsutils-linux> — publishing history / versions.
- <http://archive.ubuntu.com/ubuntu/dists/resolute/main/binary-amd64/Packages.gz> — `zfsutils-linux` Depends/version; absence of `zfs-dkms`.

Debian:
- <https://www.debian.org/CD/live/> — official live images.
- <https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/> — `.packages`, `.contents`, `.log`.
- <http://deb.debian.org/debian/dists/trixie/contrib/binary-amd64/Packages.gz> and `.../contrib/source/Sources.gz` — ZFS in contrib, zfs-linux 2.3.9.
- <http://deb.debian.org/debian/dists/trixie/main/binary-amd64/Packages.gz> — live-build 1:20250505+deb13u1.
- <https://wiki.debian.org/ZFS> — contrib + DKMS status, headers requirement, `dkms mkbmdeb`.
- <https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1117800> — zfs-dkms missing headers failure.
- <https://metadata.ftp-master.debian.org/changelogs/main/l/live-build/live-build_20250505+deb13u1_changelog> — net-root option obsolescence.
- <https://manpages.debian.org/trixie/live-build/lb_config.1.en.html> — live-build knobs.
- <https://manpages.debian.org/trixie/apt/apt-get.8.en.html> — `--no-download` wording.
- <https://manpages.debian.org/trixie/dpkg/dpkg.1.en.html> — `-i` semantics.
- <https://manpages.debian.org/trixie/live-boot-doc/live-boot.7.en.html> — `netboot=`, `fetch=`, `httpfs=`.
- Debian Live Manual: <https://live-team.pages.debian.net/live-manual/html/live-manual/> (chapters `about-project`, `the-basics`, `customizing-package-installation`, `customizing-contents`, `customizing-binary`).

OpenZFS:
- <https://openzfs.github.io/openzfs-docs/man/master/8/zfs-send.8.html>
- <https://openzfs.github.io/openzfs-docs/man/master/8/zfs-receive.8.html>
- <https://openzfs.github.io/openzfs-docs/man/v2.4/8/zfs-send.8.html>
- <https://github.com/openzfs/zfs/releases/tag/zfs-0.8.0> — raw-send introduction.
- Upstream man pages at tags `zfs-0.6.5`, `zfs-0.7.0`, `zfs-0.7.13`, `zfs-0.8.0` (fetched via
  `https://codeload.github.com/openzfs/zfs/tar.gz/refs/tags/<tag>`, file `man/man8/zfs.8`) — `-c`
  absent in 0.6.5, present from 0.7.0; `-w` absent in 0.7.13, present in 0.8.0.

---

## UNVERIFIED / open items

1. Whether the Ubuntu 26.04.1 live-server ISO's embedded `dists/resolute/main/binary-amd64/Packages`
   index actually lists `zfsutils-linux` (the index file and the `.deb` are both present; reading
   the index needs the full ISO).
2. Whether the trixie manual's `--net-root-path`/`--net-root-server` flags still function in
   `live-build 1:20250505+deb13u1` (the man page omits them and the changelog says they were
   obsoleted; the exact surviving "one" option was not identified).
3. First release that introduced `zfs send -c`: verified present in 0.7.0 and absent in 0.6.5, so
   introduced in the 0.7.0 series; the exact commit is not cited here.
4. Any first-party numeric throughput/size guidance for `zfs send`/`recv` to a file on USB — none
   found.
5. Any first-party Debian "provisioning appliance" documentation — none found.
6. Whether `zfs-dkms` run *inside a live session* is documented as problematic in so many words —
   no statement found; the conclusion above is inferred from primary facts (headers requirement,
   ephemeral overlay, live-vs-target kernel mismatch), which are cited.
