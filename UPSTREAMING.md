# Contributing the fixes to postmarketOS

A plan for sending what we found upstream, so the next A51 owner (and owners
of other old phones) doesn't hit the same problems. Nothing here is done yet.

Everything goes through postmarketOS's own GitLab and wiki, not GitHub:

- Code: <https://gitlab.postmarketos.org> (fork, push a branch, open a merge
  request). Repos: `postmarketOS/pmaports`, `postmarketOS/pmbootstrap`,
  `postmarketOS/postmarketos-android-recovery-installer`.
- Wiki: <https://wiki.postmarketos.org/wiki/Samsung_Galaxy_A51_(samsung-a51)>
- Contribution docs: <https://wiki.postmarketos.org/wiki/Contributing>

**First step: create both accounts.** New accounts may need manual approval
(spam protection), so sign up a day before you plan to submit anything.

## Plan

| # | What | Where | Kind | Effort | Status |
|---|---|---|---|---|---|
| 1 | Install notes and fixes for the A51 | wiki | page edit | ~30 min | todo |
| 2 | gzip initramfs (patch `0001`) | pmaports | merge request | ~35 min | todo |
| 3 | 4K-sector storage on old kernels (patches `0002`, `0003`) | pmaports + installer | issue first | ~1 h to write | todo |
| 4 | No check for initramfs compression vs. kernel | pmbootstrap or mkinitfs | issue | ~20 min | todo |
| 5 | Cross binutils for clang builds | pmbootstrap | merge request | ~30 min | todo |
| 6 | pmbootstrap build traps | pmbootstrap | issues | ~30 min | todo |
| 7 | Docker kernel options (patch `0004`) | pmaports | merge request | ~1 h | todo |
| 8 | Become the A51's maintainer | pmaports | merge request | ongoing | decide later |

Suggested order: 1 and 2 (quick wins), then 3 (widest impact), then the rest.
Claude can prepare the commits, issue texts and wiki markup; submitting has to
be done from your accounts.

## 1. Wiki page

Add to the A51 page (link to the README and the blog post for details):

- Installing: TWRP **ADB Sideload** of the recovery zip, built with
  `--recovery-install-partition=userdata`. The default `system` fails with
  `findfs: unable to resolve 'PARTLABEL=system'` because `system` is a logical
  partition inside `super`. No format/wipe needed before sideloading.
- After the first boot: home directory permissions break SSH key login
  (fix in README "After the first boot"); delete `/in-pmbootstrap`; Dropbear
  has no SFTP, so `scp` fails (pipe through `ssh`, or install
  `openssh-sftp-server`).
- Wi-Fi: works with the firmware package; no MAC stored, so set
  `cloned-mac-address stable`; incoming latency 10-100 ms even with power
  saving off.
- Docker: works with kernel options, crun, `rc_cgroup_mode="hybrid"` and
  `rc_cgroup_controllers="schedtune"` (README "Docker").
- Status table: mark USB networking, Wi-Fi, SSH as working on edge.
- Guide: <https://merope.dev/notes/postmarketos-on-a-samsung-galaxy-a51>

## 2. Merge request: gzip initramfs for the A51

The change is `patches/pmaports/0001-samsung-a51-specify-gzip-ing-initfs.patch`:
`deviceinfo_initfs_compression="gzip"`, `pkgrel` bump, checksum update.

- Copy the commit message style from the September sweep (pmaports#4799;
  find one with `git log --grep="gzip-ing initfs"` in pmaports), e.g.
  `device/samsung-a51: specify gzip-ing initfs`.
- Explain in the MR: the default became zstd (`58a9d9dbf3`, 2026-07-13,
  pmaports#4087); the A51 was archived on 2026-08-02 (`87850f648f`) and missed
  by the sweep; the 4.14 kernel has no `CONFIG_RD_ZSTD`, so it panics with
  `VFS: Unable to mount root fs on unknown-block(1,0)` (boot loop). Tested on
  the device.
- Before pushing: `pmbootstrap checksum device-samsung-a51`,
  `pmbootstrap lint device-samsung-a51`.
- Expect the question "why fix an archived device?" — the answer is that it
  boot-loops without it; see also item 8.

## 3. Issue: 4K-sector storage on old kernels

Affects any device with 4K-sector storage (UFS) whose kernel ignores the loop
sector size, not just the A51. Open an **issue** on pmaports before sending
patches; maintainers (initramfs: Clayton Craft, Casey Connolly) may prefer a
different design.

Points to include (details and logs in README issues 8 and 9):

- Cause: `86bdb82116` (2026-02-05, MR 7932, "use loop device for
  subpartitions") replaced `kpartx` with `losetup -P --direct-io=on`.
- Problem 1, partition table units: the recovery installer partitions the
  4K-sector device directly, so the subpartition MBR is in 4096-byte units;
  `losetup -P` reads it in 512-byte units and finds nothing ("failed to mount
  subpartitions"). `deviceinfo_rootfs_image_sector_size` can't help: the 4.14
  kernel ignores `losetup --sector-size` (still `LOG-SEC 512`).
- Problem 2, direct I/O: 512-byte direct I/O on 4K UFS is rejected
  (`exynos-ufs 13520000.ufs: Invalid bio`, mount fails with "Invalid
  argument").
- Our working approach: patch `0002` (installer rewrites the MBR in 512-byte
  units after partitioning) and patch `0003` (initramfs only uses direct I/O
  when sector sizes match). Tested by full installs on the A51.
- Alternatives to offer: initramfs detects the mismatch and falls back to
  `kpartx`; or pmbootstrap/the installer always writes 512-byte units.
- Note for the installer: its source is its own repo
  (`postmarketos-android-recovery-installer`), so the real fix is an MR there
  plus a version bump in pmaports, not a patch file inside pmaports as we did.
- Note why partitioning through a loop device in the installer doesn't work:
  TWRP enforces SELinux and denies loop devices access to block devices.

## 4. Issue: check initramfs compression against the kernel

Nothing checks that the kernel supports the initfs compression
(`CONFIG_RD_GZIP`, `CONFIG_RD_ZSTD`, ...). A mismatch is a silent boot loop.
Propose a check in pmbootstrap (kconfig check, or at install time) or in
mkinitfs. Mention that other archived devices with old kernels may have been
missed by the gzip sweep too (could list them: archived devices without
`deviceinfo_initfs_compression` whose kernel config lacks `CONFIG_RD_ZSTD`).

## 5. Merge request: cross binutils for clang builds (pmbootstrap)

`patches/pmbootstrap/0001-build-install-cross-binutils-with-clang.patch`:
`init_compiler()` installs `binutils-<arch>` with `clang`.

- Reason: kernels built with clang and `-no-integrated-as` need the GNU cross
  assembler. Without it every `cc-option` check fails and the build stops at
  the misleading `-fstack-protector-strong not supported by compiler`.
- Why not `makedepends` in the kernel APKBUILD: `binutils-aarch64` only exists
  for the host arch, so `dependency not found: binutils-aarch64`.
- Run pmbootstrap's tests and linters before pushing (see its CONTRIBUTING).

## 6. Issues: pmbootstrap build traps

One issue each (check for existing ones first):

- `noarch` packages built without `--arch` only land in the host-arch repo, so
  `install` for the device silently uses the online, unpatched package.
- Building a package during `install` (outdated package) zaps the buildroot
  and loses the rootfs mount: `tar: /mnt/rootfs_samsung-a51: Cannot open`.
- The recovery zip ships `/in-pmbootstrap`, so every later `mkinitfs` on the
  device prints `skipping (running in pmbootstrap)` and kernel updates don't
  reach the boot partition.
- `install` reuses an existing rootfs and doesn't upgrade packages already in
  it (maybe intended; at least worth a warning).
- `pmbootstrap flasher --method=adb sideload` starts a root adb server on port
  5038 that keeps the phone's USB interface claimed after it hangs.

## 7. Merge request: Docker kernel options

Patch `0004` regenerates the kernel config. pmaports has a `containers`
category in `kconfigcheck.toml`; the idiomatic MR enables the options and adds
`pmb:kconfigcheck-containers` (or `community`) to the kernel's `options`.

- Run `pmbootstrap kconfig check linux-samsung-a51` with the category and see
  which required options 4.14 can't provide.
- Consider also enabling `NF_TABLES` (exists since 3.13), which would make
  pmOS's nftables firewall and the `kconfigcheck-nftables` category work.
  Untested.
- The rest of the Docker setup (crun, cgroup hybrid, schedtune) is userspace
  config: wiki material, or a possible device-specific config package later.

## 8. Maintainership (decide later)

The A51 is archived because it had no maintainer. Adding yourself as
`maintainer=` to `device-samsung-a51` and `linux-samsung-a51` moves it back to
`device/testing` and keeps it in future sweeps. The commitment: test changes
on the phone now and then, and answer questions about it.
