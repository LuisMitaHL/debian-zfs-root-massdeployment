# remaining.md — handover for the next agent

State of the project, what is proven, what is broken, and exactly how to pick it up.
Everything below was executed unless marked otherwise.

---

## 1. What this project is

Provision **Debian 13 "trixie" servers with ZFS root**, fast and repeatably, from a mobile
one-operator setup. Two hardware classes: single-SSD mini PCs, and multi-disk servers with
custom mirror/raidz layouts.

**Read [`DESIGN.md`](DESIGN.md) first** — it is the agreed design and is current. The research
behind it is in [`research/`](research/) (primary-source, cited, with UNVERIFIED flags).

Shape of the solution:

```
Arch build host                    carrier USB                    target machine
────────────────                   ───────────                    ──────────────
build-golden.sh ─► rpool.stream.zst ┐
                   boot.tar.zst     │
                                    ├─► live env + stamp script ─► zfs-stamp.sh
build-live.sh ───► installer.iso ───┘                               ├─ partition
                                                                     ├─ mdadm /boot
                                                                     ├─ LUKS2
                                                                     ├─ zpool create
                                                                     ├─ zfs recv
                                                                     └─ grub + update-grub
                                                                          │
                                                                    first boot: seal-identity.sh
```

The ISO is **static**; the golden image and per-host profiles live on a second partition
("carrier") of the same USB, so refreshing the golden image does not mean rebuilding the ISO.

---

## 2. Repository layout

| Path | What it is |
|---|---|
| `DESIGN.md` | the agreed design — authoritative |
| `README.md` | user-facing overview, workflow, caching notes |
| `build/iso-readme.txt` | the README that `build-live.sh` puts at the ISO root and in `/root` |
| `research/*.md` | 5 primary-source research documents (cited, UNVERIFIED-marked) |
| `build/verify-host.sh` | build-host capability check |
| `build/build-golden.sh` | builds the golden ZFS dataset + `/boot` payload; `--native` runs without Docker |
| `build/build-live.sh` | builds the installer ISO (USB, sshd with per-boot root password) |
| `build/golden-customize.sh` | mmdebstrap `--customize-hook` (backports ZFS, no-hibernation, sealing unit) |
| `build/golden-packages.list` | base packages for the golden image |
| `scripts/zfs-stamp.sh` | **the stamping script** — runs in the live env, dry-run by default |
| `scripts/seal-identity.sh` | first-boot identity sealing (machine-id, SSH keys, dropbear keys, hostid) |
| `systemd/zfs-stamp-seal.service` | one-shot unit running the above |
| `profiles/` | profile schema + 3 examples (shell fragments, sourced) |
| `pick-disks.sh` | fills a profile's `DISKS` from `/dev/disk/by-id` (also at `/root` on the live ISO) |
| `tests/smoke-stamp.sh` | stamps loop disks inside the VM (fastest, least convincing) |
| `tests/installer-qemu.sh` | **drives the real installer ISO in QEMU/BIOS over serial** |
| `tests/boot-stamped.sh` | **boots a stamped image in QEMU/BIOS, answers LUKS over serial** |
| `tests/inspect-stamped.sh` | assembles a stamped image offline and dumps its boot-critical config |

Build artifacts (not in git, large): `out/debian-zfs-installer.iso` (~998 MB),
`out/lb-cache/` (~890 MB), `out/live-build/`,
`out/build-live.log`.

> Note: the PXE/netboot flow was dropped (ISO-only by decision). `out/netboot.tar.gz`
> and `tests/pxe-qemu.sh` are gone; §5.4 is kept as history.

---

## 3. Environment you are working in

- **Sandbox**: uid 1000, **no sudo**, no `/dev/loop*`, `/dev/zfs` masked. `docker` **is**
  reachable, `incus` **is** reachable and authenticated as `looper`. You cannot run real ZFS or
  mount loops *in the sandbox* — use the test VM.
- **Build host**: Arch Linux, kernel 6.18-lts, ZFS loaded (`zpool`/`zfs` present), Docker 29.8.
  The repo lives on a **btrfs subvolume mounted `nodev`** — this matters a lot (see §6).
- **Test VM**: incus VM `zfstest`, Debian 13, kernel `6.12.107+deb13-amd64`, 4 vCPU / 7.7 GB,
  `/dev/kvm` available (nested virt works). A 30 GB block volume `scratch` is attached.

### Recreating / re-attaching the test VM

```sh
# if the VM does not exist
incus launch images:debian/13 zfstest --vm -c limits.cpu=4 -c limits.memory=8GiB
incus storage volume create default scratch --type=block size=30GiB
incus config device add zfstest scratch disk pool=default source=scratch

# inside the guest: device names SWAP across reboots, so find the 30G disk by SIZE
incus exec zfstest -- bash -c 'S=$(lsblk -dno NAME,SIZE | awk "\$2==\"30G\"{print \$1}" | head -1);
  mkfs.ext4 -F "/dev/$S"; mkdir -p /mnt/scratch; mount "/dev/$S" /mnt/scratch'

# push the repo (skip out/ — it is ~2 GB)
tar cf - scripts profiles build tests | incus exec zfstest -- tar xf - -C /root/debian-zfs-root

# run things
incus exec zfstest -- bash /root/debian-zfs-root/tests/installer-qemu.sh
incus exec zfstest -- bash /root/debian-zfs-root/tests/boot-stamped.sh
```

Tools already installed in the VM: `qemu-system-x86`, `ovmf`, `mmdebstrap`, `zfs-dkms` +
`zfsutils-linux` (2.4.4 from trixie-backports), `mdadm`, `cryptsetup`, `grub-*`. Serial
consoles are driven with pure bash `/dev/tcp` (no `socat`).

**Always check for leftover state before rebuilding.** A stale `rpool` import, a stray
`/dev/mapper/zfs0`, or a leftover loop device will make `build-golden.sh` refuse to run
(`a pool named 'rpool' already exists`) or corrupt a test:

```sh
zpool list; losetup -a; dmsetup ls; grep -E "/mnt/(scratch|inspect)" /proc/mounts
```

---

## 4. What is PROVEN working

Every row below was executed; the evidence is a log or console capture in the VM.

1. **The ISO builds** — 998 MiB bootable hybrid (`iso-hybrid`, syslinux + grub-efi), ~16 min
   with a warm cache.
2. **The package cache persists** — 890 MB in `out/lb-cache/`. The speedup itself is unmeasured.
3. **The ISO boots**, both ways. **Prefer BIOS for automated testing** — no OVMF, no NVRAM, no
   `vars.fd`.
4. **The installer runs end to end in QEMU/BIOS** and stamps a real 16 G disk:
   `[ ok ] installed 'mini-single' onto 1 disk(s)`.
5. **A stamped machine BOOTS.** This was the last unknown and it now works, measured end to end:

   ```
   GRUB menu (on serial)  ->  Loading Linux 6.12.107+deb13-amd64
   Please unlock disk zfs0:            <- passphrase typed over serial
   cryptsetup: zfs0: set up successfully
   ... root=ZFS=rpool/ROOT/debian mounts, systemd starts
   Debian GNU/Linux 13 mini01 ttyS0
   mini01 login:                        <- t = 24 s from power-on
   ```

   Reproduce with `tests/boot-stamped.sh` (~1 minute).
6. **`crypttab` is keyed by LUKS UUID** (`zfs0 UUID=<uuid> ...`), verified both in the stamped
   image and by the fact that the initramfs unlocked the container by UUID at boot. Device
   renames therefore cannot break the boot.
7. **`stage_verify` works.** It catches an unbootable target *at install time* and refuses to
   print `installed`. It is what found the missing `systemd-cryptsetup` (see §5).
8. **`systemd-cryptsetup` is the key to `/etc/crypttab` at boot** (root cause of the ~90 s
   stall), and it is now in `build/golden-packages.list`.
9. **by-id paths behave**; partitions are addressed as `<by-id>-part<N>`.
10. **OpenZFS 2.4.4 compiles via DKMS** against the stock 6.12 kernel and loads.
11. **Everything on the boot path is now confirmed from the stamped machine's own journal**, not
    just from the console. One boot produced:

    ```
    Kernel command line: … root=ZFS=rpool/ROOT/debian ro quiet nohibernate zswap.enabled=1 \
                             console=tty0 console=ttyS0,115200
    zswap: loaded using pool lzo/zsmalloc
    systemd-makefs: /dev/mapper/swap successfully formatted as swap
    systemd[1]: Activated swap dev-mapper-swap.swap - /dev/mapper/swap.
    ```

    That single excerpt validates five separate pieces of plumbing at once: `update-grub` derived
    `root=ZFS=`, `nohibernate` reached the kernel, `zswap.enabled=1` was read out of
    `/etc/default/zfs-stamp-cmdline` by the stamp script, the serial console is configured, the
    bogus `zswap.compressor=zstd` is gone, and **`systemd-cryptsetup` really does create and
    activate the ephemeral encrypted swap**. Dependency failures and `Timed out waiting` lines in
    that boot: **0** (it was 1 + 1 before the fix).

    Note `zram: Added device: zram0` still appears on mini PCs — the `zram` module is loaded by
    `systemd-modules-load`, but **no swap is created on it** (no `dev-zram0.swap` unit, no
    activation line). The device node is harmless; the design's requirement is no zram *swap*.

---

## 5. What is NOT working — the actual remaining work

### 5.1 The smoke test has not been green since `stage_finish` + the UUID change

`tests/smoke-stamp.sh` was 14/14 **before** those changes and has not been re-run to green. It
is the cheapest feedback loop for the stamping half, so fixing it is worth an hour.

**Do this**: `SKIP_GOLDEN=1 bash tests/smoke-stamp.sh` and work through the assertions. Some
assertions now check a state that `stage_finish` changes (the root dataset's `mountpoint` is
`$MNT` during staging and `/` only after `stage_finish`), and there is a new `stage_verify`
stage to account for. **Beware the trap that already bit once**: do not assert
`mountpoint=/` while the target is still staged.

### 5.2 The test VM reboots mid-run — cause unknown

`tests/smoke-stamp.sh` on loop disks has twice taken the whole VM down (uptime resets, logs
lost). Candidates: OOM in a 7.7 GB VM doing ZFS + LUKS + mdadm + a chroot, or one of the
`umount -R -f` / `zfs unmount -a -f` calls.

**Capture the console during a run** rather than after — `incus console zfstest` in a background
job. `incus console --show-log` only keeps the current boot, so it shows nothing useful after a
crash. If it is OOM, note that `tests/installer-qemu.sh` runs a 4 GB QEMU inside the 7.7 GB VM
and has never crashed, so compare the two.

### 5.3 UEFI automated test drops to the firmware shell

The ISO boots UEFI fine by hand, but an automated run ends at `Shell>`: the reused
`out`-adjacent `vars.fd` accumulates NVRAM entries pointing at dead devices. Fix: copy a fresh
`/usr/share/OVMF/OVMF_VARS_4M.fd` per run **and** `-boot order=d`. BIOS works today and is what
`tests/boot-stamped.sh` uses; this is only worth fixing if you need UEFI coverage.

### 5.4 Netboot/PXE flow — dropped (kept as history)

Decision: ISO-only. `build/build-live.sh` no longer builds `out/netboot.tar.gz` and
`tests/pxe-qemu.sh` is deleted. What follows describes the old flow so nobody re-litigates it.

`out/netboot.tar.gz` (988 MB) **was produced** — the earlier
`lb binary_linux-image: cp: cannot stat 'chroot/boot/vmlinuz-*'` failure was fixed by using
`--bootloaders syslinux` (grub-* is rejected for `--binary-images netboot`).

`tests/pxe-qemu.sh` boots it end to end and **passes** (login prompt at t=77 s) using QEMU's
built-in DHCP/BOOTP + TFTP (`-netdev user,tftp=…,bootfile=pxelinux.0`) plus a local HTTP server
for the squashfs. Two things to know:

1. **The payload as shipped cannot find its root filesystem.** It contains `tftpboot/` (pxelinux
   + kernel + initrd) and `debian-live/live/filesystem.squashfs`, but the kernel command line
   baked into `tftpboot/live.cfg` is only
   `append boot=live components console=tty0 console=ttyS0,115200` — **no transport parameter** —
   and the squashfs is not inside `tftpboot/`. Add
   `fetch=http://<server>/<path>/filesystem.squashfs` (`live-boot(7)` documents `fetch=URL`).
   Do **not** follow the Live Manual's NFS recipe: it uses `--net-root-*` flags that trixie's
   `live-build` has obsoleted.
2. `tftpboot/live.cfg` has `timeout 0`, which in syslinux means **wait forever**, so the harness
   sends a keypress.

Still unproven: a real DHCP/TFTP/HTTP server (dnsmasq, isc-dhcp + tftpd-hpa …) serving bare
metal, and whether `build-live.sh` should bake a `fetch=` URL into the payload at all — it is
site-specific, so it probably belongs on the carrier like the profile does.



### 5.5 `zpool export` still fails in the live environment — a fourth cause is unidentified

This is the only issue left in the boot path, and **it is cosmetic**. The export is explicitly
non-fatal, the target boots perfectly without it (proven repeatedly, journal included), and the
live environment is torn down after each machine anyway. Its only real cost is a confusing
warning and a LUKS container left open in the *live* environment.

What was found and fixed (all real, all verified):

| # | Cause | Evidence |
|---|---|---|
| 1 | `umount` used on ZFS **dataset** mountpoints | `zpool export -f` then fails forever, with nothing mounted; only a reboot clears it |
| 2 | `zfs unmount -a` **skips `canmount=noauto`** datasets — and the staging root is exactly that | test: with `canmount=on` the dataset unmounts; with `noauto` it is silently left mounted |
| 3 | Leaving the root mounted while `stage_finish` rewrites `mountpoint=/` | `zpool export` then tries to unmount `/` |
| 4 | One unmount pass is not always enough (stacked `dev/pts`, `/dev` taking its children) | second pass was needed in a faithful reproduction |

`unmount_target()` in `zfs-stamp.sh` now does the right thing — non-ZFS mounts deepest-first with
a lazy fallback, then datasets **by name**, over up to three passes — and the "still mounted"
warning has disappeared from the installer run as a result.

What is **not** explained: with nothing mounted and the error now printed in full, the live
environment still answers `cannot export 'rpool': pool is busy`. Hypotheses tested and
**eliminated** with evidence:

- *`zfs set mountpoint`/`canmount=on` auto-mounts a dataset* — no, verified it does not.
- *`zfs-zed` holds pool handles* — it **is** running in the live environment (the medium enables
  `zfs.target` → `zfs-zed.service`), the script now stops it, and the export still failed.
- *A faithful reproduction of the whole sequence* — mounting, chroot binds, cleanup, property
  restore — **exports cleanly on the VM host.** So it is something specific to the live
  environment, not to the sequence.

Best remaining leads, in order, for whoever picks this up (~15 min per installer run to test):

1. **The other ZFS systemd units.** `zfs-mount.service` and `zfs-import-cache.service` are also
   pulled in by `zfs.target`; stop them too before exporting.
2. `zpool events` / `dmesg` at the moment of failure (the harness already dumps these — see the
   `===DIAG===` block in `tests/installer-qemu.sh`; note its `zfs get -o name,mounted,mountpoint`
   invocation is mis-quoted and errors, fix that first).
3. `ls -l /proc/*/fd 2>/dev/null | grep -i rpool` in the live environment right after the failure.
4. Whether the live environment's `/home` (the final `rpool/home` mountpoint) is itself a mount.

**Do not** spend very long on this, and **do not** turn it into a hard failure: the target boots.

### 5.6 The server class has never been booted

Only the mini profile has been installed and booted. mdadm RAID1 `/boot`, raidz topologies, the
zram path and `BOOT_MODE="both"` are exercised only by the loop-disk smoke test — which is not
green (§5.1). The mdadm boot path in particular is unproven: GRUB must assemble the array, and
`tests/boot-stamped.sh` only attaches a single virtio disk.

### 5.7 Smaller items

- **Cache speedup unmeasured** — the 890 MB cache is populated; time a second build.
- **Acceptance gate** (`DESIGN.md` §14) has never been run on real hardware: identity
  uniqueness across two machines, single-disk boot, mdadm degradation, no-hibernation checks.
- **`/etc/hostid` vs the pool-label hostid** — `zgenhostid` writes the file; whether it updates
  the running kernel hostid ZFS reads is unclear. Not fatal (the stamped image booted).

---

## 6. Hard-won gotchas — read before changing anything

Each of these cost a debugging cycle and is verified.

1. **`grub-install` does NOT write `/boot/grub/grub.cfg`.** It lays down `i386-pc/` (289
   modules), `fonts/`, `locale/` and a `grubenv` — and no menu. Without an explicit
   `update-grub` the target boots straight to the `grub>` prompt. This was the reason no stamped
   machine had ever booted. `stage_grub` now runs it, after the per-machine command line exists.
2. **`systemd-cryptsetup` is only a `Recommends` of `systemd`, and `--variant=important` drops
   Recommends.** Debian **masks** the legacy `cryptdisks.service` and `cryptdisks-early.service`
   (both are symlinks to `/dev/null`), so without the generator **`/etc/crypttab` is completely
   inert at boot**: the ephemeral swap is never created and every boot stalls ~90 s on
   `dev-mapper-swap.device`. Measured: login prompt at **t=112 s without it, t=24 s with it**.
3. **`zram-size` is an expression in MiB, not a percentage.** `zram-size = 50%` makes the
   generator exit with `Error: zram-size zram0` and create **no device**. Use `ram / 2` or
   `min(ram / 2, 4096)`. On a server (`SWAP=none`, `ZRAM=yes`) a percentage means *no swap at
   all*, silently.
4. **`systemd-zram-generator` creates zram0 even when you did not ask.** The package ships
   `/usr/lib/systemd/zram-generator.conf` with a bare `[zram0]`. An `/etc` config overrides it
   wholesale, so **always write `/etc/systemd/zram-generator.conf`**: with `[zram0]` for
   servers, without it for mini PCs. Verified: no `/etc` file → `dev-zram0.swap` is generated;
   comment-only `/etc` file → nothing.
5. **The root dataset's `mountpoint` must end up `/`, and `canmount=noauto`.** The initramfs
   mounts bootfs with `mount -o zfsutil`, and `mount.zfs` **refuses** when the target does not
   match the dataset's own `mountpoint` property:
   `cannot be mounted at '/root//mnt/inspect' due to canonicalization error` → `(initramfs)`
   shell. Staging sets it to `$MNT`, so it must be restored. `tests/inspect-stamped.sh` restores
   it on exit for this reason — if you assemble a stamped image by hand, **remember to undo it**.
6. **`zpool export` reporting "pool is busy" has TWO causes, and the second is the killer.**
   1. **`umount` on a ZFS dataset mountpoint.** Never do this. `umount` — especially `umount -l`
      — detaches the dataset without telling ZFS, and the pool becomes **permanently** busy:
      `zpool export`, `zpool export -f` and `zpool destroy -f` all refuse, with nothing in
      `/proc/mounts`, no process holding anything, and `fuser`/`findmnt`/`/proc/*/fd` all clean.
      Only a reboot clears it. Datasets must go through `zfs unmount` (or `zfs unmount -a -f`).
      This is what left the golden build's pool undestroyable after *every* run, and it is the
      bug behind the "pool is busy" that plagued the stamp script.
   2. **Nested bind mounts from the chroot**, where `umount -R` is not enough: cgroup2 at
      `/sys/fs/cgroup` is held by systemd and refuses a normal unmount, and **one refusal aborts
      the whole recursive unmount**, leaving every sibling attached. Unmount them individually,
      deepest-first, with `umount -l` as the fallback.
      Order matters: nested mounts first, then `zfs unmount`. See `unmount_target()` in
      `zfs-stamp.sh` and `cleanup_target_mounts()` in `build-golden.sh`.
7. **`chroot "$TARGET" command -v X` always fails.** `command` is a shell builtin, not a binary,
   so `chroot` tries to exec a file called `command`. It silently disabled every initramfs check
   the first time `stage_verify` ran. Use `chroot "$TARGET" sh -c 'command -v X'`.
8. **The workspace is a `nodev` btrfs subvolume.** live-build manipulates device nodes, so
   `chroot/dev/null` is unusable if the build tree is on a bind mount → every package postinst
   fails with `cannot create /dev/null: Permission denied`. **live-build must run entirely on
   the container's own filesystem**; only artifacts are copied out.
9. **live-build adds `shim-signed` automatically for UEFI**, and its postinst fails when a DKMS
   MOK key exists but is not enrolled. **ZFS must be installed from a post-package hook**
   (`config/hooks/normal/*.hook.chroot`), not from the package list, so shim configures first.
   Bonus: ZFS then comes only from backports (2.4.4).
10. **`--bootappend-live` REPLACES the entire live cmdline.** Its default is
    `boot=live components quiet splash`. Passing only `console=tty0 console=ttyS0,115200`
    **deletes `boot=live`**, and the kernel panics with
    `Attempted to kill init! exitcode=0x00000100`. Always pass the complete string.
11. **GRUB needs the font at `$prefix/fonts/unicode.pf2`**, but live-build ships it at
    `$prefix/unicode.pf2`. `config.cfg` does `loadfont $font`, and Debian's GRUB is built with
    `feature_default_font_path`, so `$font` is the *name* `unicode`. Fixed via
    `config/includes.binary/boot/grub/fonts/unicode.pf2`. **A binary-stage hook runs too late.**
12. **`serial=` belongs on `-device`, not `-drive`**: `Block format 'raw' does not support the
    option 'serial'`.
13. **`sendkey ret` timing matters.** Sent too early (t=0) it cancels OVMF's boot delay and drops
    the firmware to its UEFI shell. Send it after the boot delay (~30 s OVMF, ~12 s BIOS).
14. **Guest device names swap across reboots** (`sda`↔`sdb`). Find disks by size, never hardcode.
    This is the real-world justification for the `/dev/disk/by-id` mandate.
15. **`crypttab` key files must not end with a newline** — `crypttab(5)`: *"the entire key file
    will be used as the passphrase; the passphrase must not be followed by a newline
    character."* A trailing `\n` makes the passphrase untypeable at the prompt.
16. **Never detach loop devices while a pool is imported** — it leaves a zombie pool that can
    neither be exported nor destroyed without a reboot. Teardown order: mounts → pool → mdadm →
    loops.
    **A file-backed build pool goes zombie the same way** (this bit during a golden rebuild after
    mmdebstrap failed mid-run): `zpool destroy -f rpool` answers `pool is busy` with **nothing**
    mounted, **no** process holding it, and `fuser`/`findmnt`/`/proc/*/fd` all clean. Do not
    spend time on it — `incus stop zfstest --force && incus start zfstest`, remount
    `/mnt/scratch`, delete the stale `rpool.img`, rebuild. Note `incus restart` can time out;
    use `stop --force` + `start`.
17. **Never let two writers share the same image files.** `tests/boot-stamped.sh` copies the
    stamped image before booting it, precisely because ZFS writes to the pool during import.
18. **A failed stamp leaves the target half-mounted** unless the EXIT trap runs — hence
    `cleanup_on_exit` in `zfs-stamp.sh`.
19. **`incus stop --force` immediately after a file push loses writes.** The push is
    acknowledged as soon as the data is written to the guest's page cache; a forced stop is a
    pulled plug, so unsynced pages are gone. This silently left THREE stale files in the VM
    (`build-golden.sh`, `golden-customize.sh`, `zfs-stamp.sh`) and produced a golden image built
    from the wrong source. **Always `sync` and verify with `md5sum` after pushing**, and never
    force-stop right after one. A hash-compare loop is worth the ten seconds:
    ```sh
    for f in build/build-golden.sh scripts/zfs-stamp.sh …; do
      [ "$(md5sum "$f" | cut -c1-10)" = "$(incus exec zfstest -- md5sum "/root/repo/$f" | cut -c1-10)" ] \
        && echo "OK $f" || echo "STALE $f"
    done
    ```
20. **Useful env vars**: `SKIP_GOLDEN=1`, `KEEP_TARGET=1`, `CACHE_DIR=`, `OUT=`, `GOLDEN_WORK=`,
    `REPO=` (for `tests/installer-qemu.sh`), `DEADLINE=` (for `tests/boot-stamped.sh`).

---

## 7. How to rebuild the artifacts

```sh
cd /home/looper/GitHub/debian-zfs-root

# golden image -> out/rpool.stream.zst + out/boot.tar.zst  (~20-30 min cold)
sudo ./build/build-golden.sh            # add --clean to destroy the build pool afterwards

# installer ISO -> out/debian-zfs-installer.iso  (~16 min with a warm cache)
./build/build-live.sh

# clean the build tree (root-owned leftovers need a root container)
docker run --rm -v "$PWD/out:/out" alpine rm -rf /out/live-build
```

In the VM the golden build is:

```sh
incus exec zfstest -- bash -c 'cd /root/debian-zfs-root &&
  OUT=/mnt/scratch/smoke/out GOLDEN_WORK=/mnt/scratch/golden \
  bash build/build-golden.sh --native --clean'
```

**After changing `build/golden-packages.list` you must rebuild the golden image** — the stamping
script cannot fix a missing package. That is exactly the `systemd-cryptsetup` case: the stamp
script detects and reports it, but only a golden rebuild fixes it.

`tests/installer-qemu.sh` deliberately takes `scripts/zfs-stamp.sh` from the **carrier**, not
from the copy baked into the ISO, so a script change is testable in ~15 min instead of after a
~16 min ISO rebuild. **Rebuild the ISO before shipping** so the baked copy matches.

---

## 8. Suggested order of work

1. **Get `tests/smoke-stamp.sh` green again** — §5.1. Cheapest feedback loop. It now asserts
   `grub.cfg`, the kernel command line, `systemd-cryptsetup` and the zram config, so it should
   catch a regression in any of the bugs listed in `README.md`.
2. **Boot the server profile** (mirror, mdadm `/boot`, zram) — §5.6. Extend
   `tests/boot-stamped.sh` to attach two disks; the mdadm/GRUB path is the least-tested part of
   the design.
3. **The export wart** — §5.5, if you care. It is cosmetic and the diagnostics are ready.
4. **UEFI automated test** — §5.3 (lowest value; BIOS covers the logic).
5. **Run the acceptance gate on real hardware** — `DESIGN.md` §14.

---

## 9. Things NOT to re-litigate

These were decided deliberately in interview; the reasoning is in `DESIGN.md`:

- **No `bpool`, no ZFSBootMenu.** GRUB on UEFI and BIOS; `/boot` is ext4 (mdadm RAID1 on
  servers) so no bootloader ever reads ZFS. Keeps the future Secure Boot path to signed Debian
  GRUB + a signed `zfs.ko` (DKMS already auto-signs with `/var/lib/dkms/mok.{key,pub}`; the
  remaining work is MOK *enrollment*, which is why Secure Boot is off today).
- **ZFS from trixie-backports (2.4.4)**; no compatibility pin, because the live image is built
  from the same source as the target. Invariant: *installer OpenZFS must never exceed the
  target's.* A stock trixie ISO cannot rescue these pools.
- **No `altroot` (`-R`).** It is a *persistent* pool property, not per-import.
- **LUKS2 under ZFS**, one container per disk. Unlock via `dropbear-initramfs` now;
  Clevis-TPM2/Tang later (additive keyslots).
- **Hibernation disabled unconditionally** (nohibernate + sleep.conf.d + masked units + no
  resumable swap image).
- **Mini PCs**: ephemeral-key encrypted swap + zswap. **Servers**: zram only.
- **`/boot` outside the pool** means the golden stream does not contain `/boot`; the stamping
  script populates it from the carrier payload and regenerates the initramfs per machine.
- **`CRYPTSETUP=y` is mandatory** in `/etc/cryptsetup-initramfs/conf-hook`. Without it Debian's
  cryptsetup-initramfs never pulls itself in (root is a *dataset*, not a device) and the machine
  cannot unlock its containers. Measured: cryptsetup entries 0 → 6, dropbear 0 → 7.
- **BIOS for automated tests, UEFI as the production default.**
