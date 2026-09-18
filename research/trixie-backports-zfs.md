# Debian 13 "trixie" + trixie-backports ZFS: primary-source verification

**Research date:** 2026-09-17 (UTC). Every version, section and filename below is pinned to that date.

**Method / scope.** Primary sources only, quoted or fetched live on 2026-09-17: `packages.debian.org`,
`backports.debian.org`, `tracker.debian.org`, the Debian archive pool index, `packages.ubuntu.com`,
`archive`/`security.ubuntu.com` (actual `.deb` downloaded), the OpenZFS documentation site, the OpenZFS
git source (tags `zfs-2.3.9`, `zfs-2.4.1`, `zfs-2.4.4`) and the Debian wiki. Package contents were read
by downloading the real `.deb` files and extracting them (`ar x` + `tar`), not by trusting a web page.

**Headline correction up front:** trixie-backports does **not** carry a 2.3.x ZFS. It carries **OpenZFS
2.4.4** (`2.4.4-1~bpo13+1`, in `contrib`), accepted 2026-09-12. trixie itself carries **2.3.9-0+deb13u1**
in `contrib`. Consequently the "newer pool on the live media" problem is smaller than assumed, and the
safe compatibility pin is **not** a backports limitation — see Q5/Q6.

---

## Q1 — Exact versions currently in trixie-backports

All four packages are built from the same source package `zfs-linux`, and all live in **`contrib`**, not
`main` (Debian keeps ZFS out of `main` for the CDDL/GPL licensing reason documented on the Debian wiki).

| Binary package | trixie-backports version | Section | Arch |
|---|---|---|---|
| `zfs-dkms` | **`2.4.4-1~bpo13+1`** | `contrib` | all |
| `zfsutils-linux` | **`2.4.4-1~bpo13+1`** | `contrib` | amd64, arm64, armel, armhf, i386, ppc64el, s390x |
| `zfsutils-linux` | `2.4.3-1~bpo13+1` | `contrib` | riscv64 (not yet rebuilt to 2.4.4) |
| `zfs-initramfs` | **`2.4.4-1~bpo13+1`** | `contrib` | all |
| `zfs-zed` | **`2.4.4-1~bpo13+1`** | `contrib` | amd64, arm64, armel, armhf, i386, ppc64el, s390x |
| `zfs-zed` | `2.4.3-1~bpo13+1` | `contrib` | riscv64 |
| source `zfs-linux` | **`2.4.4-1~bpo13+1`** | `contrib` | — |

Primary sources:

- `https://packages.debian.org/trixie-backports/zfs-dkms` → "Package: zfs-dkms (2.4.4-1~bpo13+1) [ contrib ]"
- `https://packages.debian.org/trixie-backports/zfsutils-linux` → "Package: zfsutils-linux (2.4.4-1~bpo13+1 and others) [ contrib ]", per-arch table shows riscv64 `2.4.3-1~bpo13+1`
- `https://packages.debian.org/trixie-backports/zfs-initramfs` → "Package: zfs-initramfs (2.4.4-1~bpo13+1) [ contrib ]"
- `https://packages.debian.org/trixie-backports/zfs-zed` → "Package: zfs-zed (2.4.4-1~bpo13+1 and others) [ contrib ]"
- `https://tracker.debian.org/pkg/zfs-linux` → source `zfs-linux (contrib)`, `stable-bpo: 2.4.4-1~bpo13+1`; news item **"[ 2026-09-12 ] Accepted zfs-linux 2.4.4-1~bpo13+1 (source) into stable-backports (Shengqi Chen)"**
- `https://backports.debian.org/uploads/trixie-backports/` → upload table row: **`zfs-linux  2.4.4-1~bpo13+1  2026-09-12 15:53:27.021696+00  Shengqi Chen`**
- `https://backports.debian.org/Packages/` → the backports package index/search page (last edited 2026-03-15); it delegates the browseable listing to the per-suite upload tables above.
- `https://deb.debian.org/debian/pool/contrib/z/zfs-linux/` → the actual archive pool for `trixie-backports` (backports pools live in the main Debian archive), confirming the concrete files:
  `zfs-dkms_2.4.4-1~bpo13+1_all.deb`, `zfs-initramfs_2.4.4-1~bpo13+1_all.deb`,
  `zfsutils-linux_2.4.4-1~bpo13+1_amd64.deb`, `zfs-zed_2.4.4-1~bpo13+1_amd64.deb`,
  `zfs-linux_2.4.4-1~bpo13+1.dsc` / `.debian.tar.xz`, plus the older
  `…_2.4.3-1~bpo13+1_riscv64.deb`.

Notes:
- The `upload`/`last-modified` timestamps in the pool listing for the `2.4.4-1~bpo13+1` binaries are
  `2026-09-12` (e.g. `zfsutils-linux_2.4.4-1~bpo13+1_amd64.deb`, 2026-09-12 20:48 UTC). This is a 5-day-old
  upload as of the research date.
- Older backports versions are still present in the pool as history (`2.3.5-2~bpo13+1`, `2.4.3-1~bpo13+1`)
  but are superseded by `2.4.4-1~bpo13+1` in the `trixie-backports` suite.

---

## Q2 — Version in trixie itself (main archive, not backports)

**Confirmed:** `zfsutils-linux 2.3.9-0+deb13u1` in **`contrib`**.

- `https://packages.debian.org/trixie/zfsutils-linux` → "Package: zfsutils-linux (2.3.9-0+deb13u1) [ contrib ]",
  source `zfs-linux_2.3.9-0+deb13u1`.
- The same version applies to the whole source package as currently installable in trixie:
  `zfs-dkms 2.3.9-0+deb13u1 [contrib]` (`https://packages.debian.org/trixie/zfs-dkms`),
  `zfs-initramfs 2.3.9-0+deb13u1 [contrib]` (`https://packages.debian.org/trixie/zfs-initramfs`),
  `zfs-zed 2.3.9-0+deb13u1 [contrib]` (`https://packages.debian.org/trixie/zfs-zed`).

Provenance of that exact version (not the original trixie release version):
- `https://tracker.debian.org/pkg/zfs-linux` shows `stable: 2.3.2-2` but
  `stable-sec: 2.3.9-0+deb13u1`, with news entries
  "**[ 2026-08-24 ] Accepted zfs-linux 2.3.9-0+deb13u1 (source) into stable-security**" and
  "**[ 2026-08-24 ] Accepted zfs-linux 2.3.9-0+deb13u1 (source) into proposed-updates**".
- So `2.3.9-0+deb13u1` reaches trixie as a security/proposed-updates update; `2.3.2-2` was the
  trixie-release version. `packages.debian.org/trixie` already reflects `2.3.9-0+deb13u1`.

**Verdict: the team's claim is correct as stated** (package, version, section) — with the nuance that it is
the current security-updated trixie version, not the version trixie shipped at release.

---

## Q3 — Prebuilt kernel-module packages in trixie-backports?

**No.** trixie-backports ships **DKMS source only** (`zfs-dkms`); there is no `zfs-modules-*` binary
package. `zfs-modules` is a **virtual** package whose **only** provider is `zfs-dkms`.

- `https://packages.debian.org/trixie-backports/zfs-modules` →
  "Virtual Package: zfs-modules … Packages providing zfs-modules: **zfs-dkms**" (single provider).
- `https://packages.debian.org/trixie/zfs-modules` → same single provider in trixie.
- `https://packages.debian.org/search?keywords=zfs-modules&searchon=names&suite=trixie-backports&section=all`
  → "Sorry, your search gave no results" (no `zfs-modules-<kernel>` packages).
- `https://deb.debian.org/debian/pool/contrib/z/zfs-linux/` → the complete file list for the source
  package contains **no** `zfs-modules-*` file; the only kernel-module artifact is
  `zfs-dkms_*_all.deb`.
- Dependency evidence that the virtual package really resolves to DKMS:
  `zfs-initramfs` (trixie-backports) has `dep: zfs-modules` documented as
  "virtual package provided by zfs-dkms"
  (`https://packages.debian.org/trixie-backports/zfs-initramfs`), as do `zfsutils-linux` and `zfs-zed`
  (`https://packages.debian.org/trixie-backports/zfsutils-linux`,
  `https://packages.debian.org/trixie-backports/zfs-zed`).

Contrast (not Debian): Ubuntu's `zfs-dkms` page lists prebuilt-module providers such as
`linux-image-7.0.0-*-nvidia` and `linux-main-modules-zfs-7.0.0-*-gke`
(`https://packages.ubuntu.com/resolute/zfs-dkms`). Debian has no equivalent; every Debian kernel upgrade
on a DKMS ZFS host needs a rebuild.

---

## Q4 — Actual filenames in `/usr/share/zfs/compatibility.d/`

The lists for (a) and (b) were read directly out of the real `.deb` archives (downloaded and extracted);
(c) was read from the Ubuntu package filelist. See "How this was checked" at the end.

### (a) Debian trixie — `zfsutils-linux 2.3.9-0+deb13u1` (52 files)

```
2018  2019  2020  2021
compat-2018  compat-2019  compat-2020  compat-2021
freebsd-11.0 freebsd-11.1 freebsd-11.2 freebsd-11.3 freebsd-11.4
freebsd-12.0 freebsd-12.1 freebsd-12.2 freebsd-12.3 freebsd-12.4
freebsd-13.0 freebsd-13.1 freebsd-13.2
freenas-11.0 freenas-11.1 freenas-11.2 freenas-11.3 freenas-9.10.2
grub2  grub2-2.06  grub2-2.12
openzfs-2.0-freebsd  openzfs-2.0-linux
openzfs-2.1-freebsd  openzfs-2.1-linux
openzfs-2.2  openzfs-2.2-freebsd  openzfs-2.2-linux
openzfs-2.3  openzfs-2.3-freebsd  openzfs-2.3-linux
openzfsonosx-1.7.0 openzfsonosx-1.8.1 openzfsonosx-1.9.3 openzfsonosx-1.9.4
truenas-12.0
ubuntu-18.04 ubuntu-20.04 ubuntu-22.04
zol-0.6.1 zol-0.6.4 zol-0.6.5 zol-0.7 zol-0.8
```

Source (filelist): `https://packages.debian.org/trixie/amd64/zfsutils-linux/filelist`.
Source (archive): `https://deb.debian.org/debian/pool/contrib/z/zfs-linux/zfsutils-linux_2.3.9-0+deb13u1_amd64.deb`.

### (b) Debian trixie-backports — `zfsutils-linux 2.4.4-1~bpo13+1` (55 files)

Identical to (a) plus **`openzfs-2.4`, `openzfs-2.4-freebsd`, `openzfs-2.4-linux`**:

```
… (all 52 entries from (a)) …
openzfs-2.4  openzfs-2.4-freebsd  openzfs-2.4-linux
```

Source (filelist): `https://packages.debian.org/trixie-backports/amd64/zfsutils-linux/filelist`.
Source (archive): `https://deb.debian.org/debian/pool/contrib/z/zfs-linux/zfsutils-linux_2.4.4-1~bpo13+1_amd64.deb`.

### (c) Ubuntu 26.04 "resolute" — `zfsutils-linux 2.4.1-1ubuntu5.1` (55 files)

The file **set is byte-for-byte the same list as (b)** (55 entries): the same 52 from (a) plus
`openzfs-2.4`, `openzfs-2.4-freebsd`, `openzfs-2.4-linux`. A programmatic diff of the Ubuntu filelist
against the trixie-backports filelist returned **no differences**.

Source (filelist): `https://packages.ubuntu.com/resolute/amd64/zfsutils-linux/filelist`.
Source (version/section): `https://packages.ubuntu.com/resolute/zfsutils-linux` →
"Package: zfsutils-linux (2.4.1-1ubuntu5.1 and others) [ security ]", source `zfs-linux_2.4.1`.
Source (archive, content verification): the `.deb` was downloaded from
`http://security.ubuntu.com/ubuntu/pool/main/z/zfs-linux/zfsutils-linux_2.4.1-1ubuntu5.1_amd64.deb`
and extracted.

### Upstream provenance of the `-linux` files

The `openzfs-2.3-linux`, `openzfs-2.3-freebsd`, `openzfs-2.4-linux`, `openzfs-2.4-freebsd` names are
**generated at install time**, not stored as separate files in the upstream git tree. The upstream tree
contains only `openzfs-2.3` and `openzfs-2.4` (plus per-OS names for 2.0/2.1). The install list and
symlink mapping live in `cmd/zpool/Makefile.am`
(`https://github.com/openzfs/zfs/blob/zfs-2.4.4/cmd/zpool/Makefile.am`):
`zpoolcompatdir = $(pkgdatadir)/compatibility.d`, with `openzfs-2.3` and `openzfs-2.4` in
`dist_zpoolcompat_DATA`, and a symlink table mapping e.g. `openzfs-2.3 → openzfs-2.3-linux,
openzfs-2.3-freebsd` and `openzfs-2.4 → openzfs-2.4-linux, openzfs-2.4-freebsd`. The user-facing
semantics are documented in
[`zpool-features(7)`](https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html)
("Compatibility feature sets"): filenames are resolved relative to `/etc/zfs/compatibility.d`
(local, precedence) or `/usr/share/zfs/compatibility.d` (distribution-shipped).

---

## Q5 — Highest-numbered `openzfs-<version>-linux` in each environment

| Environment | OpenZFS | Highest `openzfs-<v>-linux` | `openzfs-2.4-linux`? | `openzfs-2.3-linux`? |
|---|---|---|---|---|
| (a) Debian trixie | 2.3.9 | **`openzfs-2.3-linux`** | **No** | Yes |
| (b) trixie-backports | 2.4.4 | **`openzfs-2.4-linux`** | **Yes** | Yes |
| (c) Ubuntu 26.04 | 2.4.1 | **`openzfs-2.4-linux`** | **Yes** | Yes |

Beyond the `-linux` variants there is also a generic `openzfs-2.4` (and `openzfs-2.3`) file; the `-linux`
name is the Linux-specific alias of the same feature set.

**The three `openzfs-2.3-linux` files are byte-identical.** MD5 `9973b31dd85a1c98b33ee284a7112106` for:

- Debian trixie `zfsutils-linux_2.3.9-0+deb13u1_amd64.deb`
- Debian trixie-backports `zfsutils-linux_2.4.4-1~bpo13+1_amd64.deb`
- Ubuntu resolute `zfsutils-linux_2.4.1-1ubuntu5.1_amd64.deb`
- upstream `cmd/zpool/compatibility.d/openzfs-2.3` at tags `zfs-2.3.9`, `zfs-2.4.1` and `zfs-2.4.4`

First line: `# Features supported by OpenZFS 2.3 on Linux and FreeBSD`. So the "2.3 feature set" is a
frozen, shared contract, not a per-distro redefinition.

**The two `openzfs-2.4-linux` files are byte-identical.** MD5 `f0262423aa96d920a743f272fc9f43aa` for the
trixie-backports `.deb`, the Ubuntu `.deb`, and upstream `openzfs-2.4` at `zfs-2.4.1` and `zfs-2.4.4`.
First line: `# Features supported by OpenZFS 2.4 on Linux and FreeBSD`.

The 2.4 set adds these features over the 2.3 set (diff of the two upstream files):
`block_cloning_endian`, `dynamic_gang_header`, `draid_failure_domains`, `physical_rewrite`,
`raidz_expansion`, `vdev_zaps_v2`.

---

## Q6 — Practical consequence for a pool created by Ubuntu 26.04 live media

### Case A: pool created with `zpool create -o compatibility=openzfs-2.3-linux …`

**Yes — Debian trixie (2.3.9) imports it read-write**, and trixie-backports (2.4.4) obviously can too.

Reasoning, all from primary sources:

1. `-o compatibility=<file>` restricts enablement to the features listed in all requested feature-set
   files; everything else stays disabled/absent. `zpool-create(8)`:
   "By default all supported features are enabled on the new pool. The `-d` option and the
   `-o compatibility` property … can be used to restrict the features that are enabled, so that the pool
   can be imported on other releases of ZFS."
   ([zpool-create(8)](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-create.8.html);
   [zpool-features(7)](https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html)).
2. The `openzfs-2.3-linux` file consumed by Ubuntu 2.4.1 is **byte-identical** to the one shipped by
   Debian trixie 2.3.9 (Q5). Every feature the flag enables is therefore a feature 2.3.9 supports.
3. `zpool-features(7)`: a feature's on-disk changes are enabled by the import test only if the feature is
   *active*; "active … Support for this feature is required to import the pool in read-write mode." Since
   no feature outside the 2.3 set can be enabled (and none can be activated without being enabled), the
   pool's active set is a subset of what 2.3.9 supports.
4. The `compatibility` property is persistent on the pool, so a later `zpool upgrade` on the pool remains
   pinned to the 2.3 set — the doc notes `zpool upgrade` "controls which features are enabled when using
   `zpool upgrade`" and that `zpool status` will not warn about disabled features outside the set.

This is the mechanism the Debian+OpenZFS ecosystem intends for exactly this use case.

### Case B: pool created **without** the flag (defaults) on Ubuntu 2.4.1

`zpool create` with the default `compatibility=off` enables **all** features the creating system
supports, i.e. the full 2.4 set including the six 2.4-only features listed in Q5. What Debian sees then
depends on whether any unsupported feature has become **active**:

- OpenZFS distinguishes *enabled* from *active*
  ([Feature Flags](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Pool%20Structure/Feature%20Flags.html),
  [zpool-features(7)](https://openzfs.github.io/openzfs-docs/man/master/7/zpool-features.7.html)):
  - `enabled` — "marked as enabled, but the on-disk format change has **not happened yet**. The pool can
    still be imported by software that does not know the feature — until something triggers the change".
  - `active` — "the format change is in effect. Software must support the feature to import the pool
    read-write."
  In source terms, only features with a non-zero on-disk refcount are treated as unsupported
  (`module/zfs/zfeature.c`, `spa_features_check()`: `za->za_first_integer != 0 && !zfeature_is_supported(...)`;
  `feature_enable_sync()` writes refcount 0 unless the feature is activate-on-enable).
- **Read-write import fails** as soon as any active feature is unsupported by the importer.
  `module/zfs/spa.c` `spa_ld_check_features()` sets `missing_feat_writep`, and `spa_load()` fails with
  `VDEV_AUX_UNSUP_FEAT` / `ENOTSUP` (`spa_load_failed(spa, "pool uses unsupported features")`).
- User-visible output (OpenZFS `lib/libzfs/libzfs_pool.c`, `zpool_import()` case `ENOTSUP`, and
  `cmd/zpool/zpool_main.c` status/import listing):
  - `zpool import` (listing): *"The pool cannot be imported in read-write mode. Import the pool with
    '-o readonly=on', access the pool on a system that supports the required feature(s), or recreate the
    pool from backup."*
  - actual import: *"cannot import '<pool>': unsupported version or feature"* followed by
    *"This pool uses the following feature(s) not supported by this system:"* and, if every unsupported
    feature is read-only compatible,
    *"All unsupported features are only required for writing to the pool. The pool can be imported using
    '-o readonly=on'."*
  - The `EZFS_BADVERSION` string is literally **"unsupported version or feature"**
    (`lib/libzfs/libzfs_util.c`); it is **not** the phrase the team used.
- **Read-only fallback is conditional.** It is offered only when *all* unsupported active features are
  read-only compatible. Four of the six 2.4-only features are **not** read-only compatible
  (`dynamic_gang_header`, `draid_failure_domains`, `raidz_expansion`, `vdev_zaps_v2`; the compatibility
  matrix marks only `block_cloning_endian` and `physical_rewrite` as read-only compatible:
  [Feature Flags matrix](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Pool%20Structure/Feature%20Flags.html)).
  So a 2.4.1 pool with those features active cannot be imported by trixie at all, not even read-only.

**Myth check on the exact quoted error.** The literal string
`"pool is formatted using a newer ZFS version"` **does not exist anywhere in the OpenZFS 2.4.4 source
tree** — a recursive grep of the full upstream `zfs-linux_2.4.4.orig.tar.gz` (34,544,757 bytes) returned
nothing. **UNVERIFIED as an OpenZFS message.** The real, source-owned strings for this situation are the
ones quoted above. The closest legacy-version strings are in `cmd/zpool/zpool_main.c`:
`ZPOOL_STATUS_VERSION_NEWER` → *"The pool is formatted using an incompatible version."* and, in
`zpool status`, *"The pool has been upgraded to a newer, incompatible on-disk version. The pool cannot be
accessed on this system."* — but these describe **legacy on-disk version numbers**, not feature flags.

---

## Q7 — Myth: "if the pool has newer features we can just `zpool upgrade` later"

**False — `zpool upgrade` cannot rescue this situation.**

Primary source, [`zpool-upgrade(8)`](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-upgrade.8.html):

> "`zpool upgrade [-V version] -a | pool …` — **Enables all supported features on the given pool.** If the
> pool has specified compatibility feature sets using the `-o compatibility` property, only the features
> present in all requested compatibility sets will be enabled. If this property is set to `legacy` then no
> upgrade will take place. Once this is done, the pool will no longer be accessible on systems that do not
> support feature flags."

Key points:

- `zpool upgrade` only **adds** the features that the *currently running* ZFS build supports. It has no
  knowledge of features it does not understand, and there is no mechanism to **remove/deactivate** a
  feature that is already active on disk. The [Feature Flags](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Pool%20Structure/Feature%20Flags.html)
  documentation states it explicitly: "**Features cannot be disabled once enabled.**" and "**Upgrading is
  one-way.** … Once enabled features become `active`, the pool is no longer importable by software that
  does not support them."
- In the problem direction (pool created by a **newer** OpenZFS than the importer), `zpool upgrade` does
  not even run, because the pool can't be imported first. OpenZFS's own remediation text for
  `ZPOOL_STATUS_VERSION_NEWER` is: *"Access the pool from a system running more recent software, or
  restore the pool from backup."* (`cmd/zpool/zpool_main.c`, `zpool status` action string). The
  `zpool upgrade` path only ever runs *forward* (older pool → newer software), never backward.
- Therefore the only correct preventive measure is the one in Q6: pin the feature set at creation with
  `-o compatibility=openzfs-2.3-linux` (or `openzfs-2.3`). After the fact, on an already-imported pool,
  `zpool upgrade` is the *danger*, not the fix, because it can activate newer features and make the pool
  unreadable on the older/other system.

---

## Q8 — Installing `zfs-dkms` from trixie-backports against a trixie kernel

**Works, with the usual DKMS requirements; kernel version is within the supported range.**

### Kernel-version constraints (documented)

- OpenZFS 2.4.4 `META` file: **`Linux-Minimum: 4.18`**, **`Linux-Maximum: 7.2`**
  (`https://github.com/openzfs/zfs/blob/zfs-2.4.4/META`).
- Debian trixie's current kernel: `linux-image-amd64 6.12.107-1`
  (`https://packages.debian.org/trixie/linux-image-amd64`).
- trixie-backports' kernel: `linux-image-amd64 7.1.8-1~bpo13+1`
  (`https://packages.debian.org/trixie-backports/linux-image-amd64`).
- Both `6.12.107` and `7.1.8` are inside `[4.18, 7.2]`, so OpenZFS 2.4.4 supports either. Note that
  `7.2` is an upper bound declared upstream; a future backports kernel newer than 7.2 would not be
  covered by the 2.4.4 `META` (a new ZFS build would be required). Mark that forward-looking statement as
  an inference from `META`, not a documented Debian policy.
- The Debian packaging changelog shows active kernel-compatibility work: `2.4.2-1` "fixed support for RT
  kernels, compatibility with Linux 7.0", and `2.4.3-2` "`d/patches`: bump META to 7.1 (Closes:
  #1141831)" — i.e. Debian itself adjusts the supported-kernel ceiling for the trixie kernel line.
  (`changelog.Debian.gz` inside `zfsutils-linux_2.4.4-1~bpo13+1_amd64.deb`; also
  `https://tracker.debian.org/pkg/zfs-linux` changelog links.)

### Build dependencies

- `zfs-dkms` Depends: `debconf (>= 0.5) | debconf-2.0`, **`dkms (>= 3.0.11)`**, `file`,
  `libc6-dev | libc-dev`, `libpython3-stdlib`, `lsb-release`; Recommends: `linux-libc-dev`,
  `linux-libc-dev (>= 4.18~)`, `zfs-zed`, `zfsutils-linux`. It **does not** depend on
  `linux-headers-*` (`https://packages.debian.org/trixie-backports/zfs-dkms`).
- **`linux-headers-*` is nevertheless required to build the module.** Debian wiki, ZFS page:
  "The modules will be built automatically only for kernels that have the corresponding
  `linux-headers` package installed. Install the `linux-headers-<arch>` package to always have the latest
  linux headers installed (analog to the `linux-image-<arch>` package)."
  (`https://wiki.debian.org/ZFS`). The same page recommends installing ZFS from backports
  (`sudo apt install -t stable-backports zfsutils-linux`) and shows `sudo apt install linux-headers-amd64`
  as a prerequisite.
- The OpenZFS *Debian Trixie Root on ZFS* guide installs `linux-headers-generic` as a workaround for
  Debian bug **#1091428** before installing `zfsutils-linux`
  (`https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html`,
  bug: `https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1091428`).
- The Debian package `README.Debian` documents that Debian's installer gets no in-tree ZFS udeb modules
  ("zfs udeb modules are not built in-tree with the linux kernel") — another statement that Debian's ZFS
  is DKMS-built, not a kernel-bundled module.

**Practical answer:** `apt install -t trixie-backports zfs-dkms` on trixie will build OpenZFS 2.4.4
against the running kernel **provided the matching `linux-headers-<version>-<arch>` (or
`linux-headers-amd64`) package is installed**, and `dkms` ≥ 3.0.11 is present. Installing the headers
before `zfs-dkms` avoids a build failure; installing `linux-headers-amd64` (and keeping it installed) is
what makes future kernel upgrades rebuild ZFS automatically.

---

## How the package contents were checked (reproducible)

```sh
# Debian trixie and trixie-backports zfsutils-linux
base=https://deb.debian.org/debian/pool/contrib/z/zfs-linux
curl -O $base/zfsutils-linux_2.3.9-0+deb13u1_amd64.deb
curl -O $base/zfsutils-linux_2.4.4-1~bpo13+1_amd64.deb
mkdir -p x && (cd x && ar x ../zfsutils-linux_2.4.4-1~bpo13+1_amd64.deb)
tar -tf x/data.tar.* | grep compatibility.d

# Ubuntu 26.04 zfsutils-linux 2.4.1-1ubuntu5.1
curl -O http://security.ubuntu.com/ubuntu/pool/main/z/zfs-linux/zfsutils-linux_2.4.1-1ubuntu5.1_amd64.deb
# (same ar/tar extraction; md5 of openzfs-2.3-linux and openzfs-2.4-linux compared)

# Myth string, against the full upstream source
curl -O $base/zfs-linux_2.4.4.orig.tar.gz   # 34,544,757 bytes
tar -xzf zfs-linux_2.4.4.orig.tar.gz
grep -rn "newer ZFS version" zfs-2.4.4/      # -> no matches
```

## Explicit UNVERIFIED / caveats

- **UNVERIFIED as an OpenZFS message:** the literal phrase *"pool is formatted using a newer ZFS
  version"*. It is not present in the OpenZFS 2.4.4 source tree (full recursive grep). Do not quote it as
  an OpenZFS error; use the actual strings in Q6.
- **Date-pinned:** all versions are as of 2026-09-17. Backports changes weekly (the 2.4.4 backport is only
  5 days old); re-check `https://tracker.debian.org/pkg/zfs-linux` before relying on these strings.
- **Risk assessment vs. absolute guarantee (Case B in Q6):** whether a *particular* 2.4.1-created pool
  imports depends on which features are *active* on that specific pool. The absolutely safe path is the
  compatibility flag in Case A; the failure strings and code paths in Case B are quoted directly from
  source, but I did not execute a 2.4.1↔2.3.9 pool exchange (no such binaries were run here).
