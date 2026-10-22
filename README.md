# postmarketOS on the Samsung Galaxy A51 (headless homelab server)

Notes, fixes and scripts for building and installing postmarketOS on an old
Samsung Galaxy A51 (SM-A515F, `samsung-a51`) to use as a small headless server
(secondary DNS and other light tasks). No GUI; the screen will be turned off.

This directory is also pmbootstrap's work dir. Git only tracks our own files
(see `.gitignore`); chroots, caches, built packages and the pmbootstrap and
pmaports checkouts are downloaded/generated and ignored.

```
README.md                this file
config/                  snapshot of ~/.config/pmbootstrap_v3.cfg
patches/pmbootstrap/     fixes for the pmbootstrap checkout   (./pmbootstrap)
patches/pmaports/        fixes for the pmaports checkout      (./cache_git/pmaports)
scripts/apply-patches.sh apply all patches (idempotent)
scripts/seed-distfiles.sh pre-download/verify sources that fail to fetch
```

## Status

| Step | State |
|---|---|
| Build packages and recovery zip | works with the patches below |
| Kernel boots | works (gzip initramfs) |
| Initramfs finds the root partition | **broken**: 4K-sector subpartition issue, see [Issue 8](#8-initramfs-cant-find-the-subpartitions-4k-sectors) |
| SSH, Wi-Fi, DNS, screen off | not started yet |

## Device facts

- SoC Exynos 9611, UFS storage with **4096-byte logical sectors**.
- Device is **archived** in pmaports (maintainer inactive), so it only exists on
  the `edge` channel and nothing is tested upstream.
- Kernel: downstream `linux-samsung-a51` 4.14.113, built with clang.
- TWRP is installed as recovery.
- pmOS lives on the `userdata` partition (`/dev/block/sda32`, ~111 GiB),
  which contains its own MBR with `pmOS_boot` (ext2) and `pmOS_root` (ext4).
  That is why TWRP shows "Failed to mount /data (Invalid argument)".
- `system`/`vendor`/`product` are logical partitions inside `super`; they still
  contain leftovers of Android and are not used.
- Downstream devices use **Dropbear** as SSH server instead of OpenSSH
  (`postmarketos-base-downstream-dropbear`).

## Versions this was done with (2026-10-22)

| | |
|---|---|
| pmbootstrap | 3.12.1, `ff954a63c7a5ead5045150f5a79f035259512df2` |
| pmaports | `main`, `78e02f370c4e90f53e11fc3d728e3c67fdbaeab6` |
| Compiler | clang 23.1.3, binutils 2.45.1 |
| postmarketos-initramfs | 3.12.5-r0 |
| Host | Fedora, kernel 7.2 |

## Quick start (rebuild from scratch)

```sh
cd ~/Documents/Projects/pmos-a51

# 1. pmbootstrap init (answers below), then apply our fixes
pmbootstrap init
scripts/apply-patches.sh

# 2. seed sources whose upstream hosts are flaky/down
scripts/seed-distfiles.sh "/run/media/ahmed/Projects/pmos builds/console-pmos-samsung-a51.zip"

# 3. keep sudo alive during the long kernel build (optional, see Issue 4)
sudo -v && (while true; do sudo -n -v; sleep 60; done) &

# 4. build the TWRP zip, installing onto userdata
pmbootstrap install --android-recovery-zip --recovery-install-partition=userdata
kill %1

# 5. phone: TWRP > Advanced > ADB Sideload (leave wipe options unticked)
adb -s <SERIAL> sideload \
  chroot_buildroot_aarch64/var/lib/postmarketos-android-recovery-installer/pmos-samsung-a51.zip
```

Note: `pmbootstrap pull` (or a `git pull` in pmaports) will conflict with the
applied patches. Stash or reset them, pull, then run `scripts/apply-patches.sh`
again.

### `pmbootstrap init` answers

| Prompt | Answer | Why |
|---|---|---|
| Channel | `edge` | archived devices only exist on edge |
| Vendor / codename | `samsung` / `a51` | accept the "archived" warning |
| Kernel | `linux-samsung-a51` (only option) | |
| Username | `ahmed` | |
| User interface | **`console`** | no GUI, but brings NetworkManager + SSH. `none` is too bare |
| UI extras | no | |
| Service manager | **`openrc`** | systemd needs newer kernel features than 4.14 |
| Extra packages | `htop,nano,chrony,unbound,dnsmasq,bind` | pick one DNS server later; only enable one (port 53) |
| Timezone | `Africa/Cairo` | |
| SSH keys | yes | but see the note below |
| Build outdated packages | yes | archived device, no binary packages |

The recovery zip **excludes `/home`**, so the SSH keys copied by pmbootstrap
don't end up on the phone. Use password login first, then `ssh-copy-id`.

## Issues found and how they were fixed

### 1. Firmware download fails: `dumps.tadiphone.dev` is down

```
Fetching ...firmware-samsung-a51-<commit>-mx::https://dumps.tadiphone.dev/...
wget: can't connect to remote host (185.24.54.138): Connection refused
```

The host refuses connections on port 443 (also when resolved via 1.1.1.1, so
it is not a local DNS/ad-blocker problem). The four Wi-Fi firmware files
(`mx`, `mx140.bin`, `mx140_wlan.hcf`, `mx140_wlan_sw.hcf`) were extracted from
an older working pmOS recovery zip (`rootfs.tar.gz` inside it, path
`lib/firmware/postmarketos/samsung-a51/mx140/`). All four matched the
APKBUILD's sha512sums exactly. They are placed in `cache_distfiles/` under the
names abuild expects, which makes abuild skip the download.

**Fix:** `scripts/seed-distfiles.sh <old zip>`. The firmware is proprietary, so
it is not committed here; keep the old zips around.

### 2. Kernel source download timed out (GitHub)

A one-off network timeout fetching the kernel tarball from GitHub. Not DNS: the
local resolver and 1.1.1.1 returned the same IPs.

**Fix:** `scripts/seed-distfiles.sh` downloads it with retries and verifies the
checksum before it goes into `cache_distfiles/`.

### 3. Kernel build: `-fstack-protector-strong not supported by compiler`

```
Cannot use CONFIG_CC_STACKPROTECTOR_STRONG: -fstack-protector-strong not supported by compiler
make[1]: *** [Makefile:1251: prepare-compiler-check] Error 1
```

The error message is misleading. The A51 kernel Makefile builds with clang but
passes `-no-integrated-as` and `--prefix=aarch64-alpine-linux-musl-`, so clang
needs the GNU cross **assembler**. For clang builds pmbootstrap's
`init_compiler()` only installed `clang` (gcc builds get `gcc-<arch>`, which
pulls in binutils). With no assembler, every `cc-option` probe (which compiles
with `-Werror`) fails, and the stack-protector check is just the first one to
be reported. The February 2025 builds most likely worked because older
pmbootstrap also installed the gcc toolchain.

Adding `binutils-aarch64` to the kernel APKBUILD's `makedepends` does **not**
work: pmbootstrap resolves an aarch64 package's dependencies against the
aarch64 index, and `binutils-aarch64` only exists as an x86_64 package
(`ERROR: linux-samsung-a51: dependency not found: binutils-aarch64`).

**Fix:** `patches/pmbootstrap/0001-build-install-cross-binutils-with-clang.patch`
installs `binutils-<arch>` alongside `clang` in the native chroot.

### 4. `sudo losetup --json --list` failed after the kernel build

`sudo: timed out reading password`. The kernel build takes ~12 minutes;
afterwards pmbootstrap needs root again, sudo prompted and nobody typed the
password within 5 minutes. The built kernel package is kept, so just re-run.

**Fix:** keep sudo's credential cache alive during long builds (step 3 of the
quick start).

### 5. Recovery installer: "Extracting partition table... Failed"

`/tmp/postmarketos/pmos.log` in TWRP showed:

```
findfs: unable to resolve 'PARTLABEL=system'
```

The default `--recovery-install-partition` is `system`. On the A51, `system` is
a logical partition inside `super`; TWRP's `/recovery.fstab` lists it as plain
`system` (no `/dev/...` path), so the installer can't find it. Reading the
phone showed that the previous pmOS install actually lived on `userdata`, which
has a real GPT label.

**Fix:** build the zip with `--recovery-install-partition=userdata`. No need to
Format Data / wipe Dalvik / wipe cache first: the old routine was only needed
because TWRP's internal storage lives on `/data`, which was required to
*copy* a zip to the phone. Sideload streams over USB, and the installer
repartitions the raw `userdata` block device itself.

### 6. adb: "waiting for device", "device not found", TWRP hanging after install

- `pmbootstrap flasher --method=adb sideload` starts its **own root adb server
  on port 5038** inside the chroot. It hung at "waiting for device" (an Android
  emulator was also connected), but stayed running and kept the phone's USB
  interface claimed (`USBDEVFS_CLAIMINTERFACE failed: Device or resource busy`
  in `/tmp/adb.1000.log`), so the host's normal adb couldn't see the phone.
- With two devices attached, adb needs `-s <SERIAL>`.
- With the 5038 server holding the device, TWRP hung at "Cancelling ADB
  sideload" after a successful install.

**Fix:** use the host's adb (`sudo dnf install android-tools`) directly,
always with `-s <serial>`, and stop leftover servers with
`sudo adb -P 5038 kill-server`. A sideload ending with
`adb: failed to read command: Success` at ~50% is normal.

### 7. Boot loop: penguins, then instant reboot (kernel panic)

The crash log survives a reboot into TWRP:
`adb shell cat /sys/fs/pstore/console-ramoops-0` (or `/proc/last_kmsg`).

```
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(1,0)
```

The kernel never unpacked the initramfs. The new initramfs was
**zstd**-compressed (`28 b5 2f fd` magic); the 4.14 kernel only supports
gzip/bzip2/lzma/xz/lzo/lz4 (`CONFIG_RD_*`). The February build's initramfs was
gzip.

How it happened (from pmaports history): zstd was planned to become the default
initfs compression (`58a9d9dbf3`, 2026-07-13, pmaports#4087), and in September
devices with old kernels got `deviceinfo_initfs_compression="gzip"` in a sweep
(pmaports#4799). The A51 had been **archived on 2026-08-02** (`87850f648f`) and
was missed. Nothing checks the kernel's `CONFIG_RD_*` against the chosen
compression.

**Fix:** `patches/pmaports/0001-samsung-a51-specify-gzip-ing-initfs.patch` sets
`deviceinfo_initfs_compression="gzip"` (and bumps `pkgrel`, updates the
checksum).

### 8. Initramfs can't find the subpartitions (4K sectors)

With the gzip initramfs the kernel boots, but the initramfs drops into the
debug shell:

```
Trying to mount subpartitions for 10 seconds...
Mount subpartitions of /dev/sda32
ERROR: failed to mount subpartitions!
```

Cause:

- The A51's UFS has 4096-byte logical sectors (`/sys/block/sda/queue/logical_block_size`).
  The recovery installer runs `parted` on `/dev/block/sda32` directly, so the
  MBR it writes uses **4 KiB units** (boot starts at sector 2048 = 8 MiB, root at
  62464 = 244 MiB).
- `mount_subpartitions()` in `/init_functions.sh` (initramfs 3.12.5) maps the
  partition with `losetup -Pf`, which reads the MBR in **512-byte units** unless
  `--sector-size` is passed (from `deviceinfo_rootfs_image_sector_size`).
- This 4.14 Samsung kernel **ignores the loop sector size**: with
  `losetup -b 4096` (with and without `--direct-io`), `losetup -l` still
  reports `LOG-SEC 512`. So setting `deviceinfo_rootfs_image_sector_size`
  alone can't fix it.
- The filesystems themselves are fine: mapped by byte offset
  (`losetup -o $((62464*4096))`), `pmOS_root` and `pmOS_boot` both mount.

The February installs used the identical 4K-unit table and booted, so the older
initramfs presumably mapped subpartitions differently (likely `kpartx`, which
honours the real sector size). This is an inference, not verified.

**Planned permanent fix:** make the recovery installer write the subpartition
table in 512-byte units (i.e. partition through a 512-byte loop device), so the
initramfs' default `losetup -P` reads it correctly. This will become a patch in
`patches/pmaports/`.

**One-off workaround for an existing install:** rewrite only the MBR of
`sda32` in 512-byte units with the same byte offsets (p1 start 16384,
p2 start 499712). Filesystems are untouched.

## Debugging techniques that worked

- **Build logs:** `pmbootstrap log`, or the text above the `^^^` line in
  `log.txt` in this directory.
- **Recovery installer log:** in TWRP, `adb shell cat /tmp/postmarketos/pmos.log`
  (lost on reboot).
- **Kernel panic log:** boot into TWRP right after the crash, then
  `adb shell cat /sys/fs/pstore/console-ramoops-0`.
- **Initramfs debug shell over USB:** the debug shell has no telnet by default.
  Type `telnetd -l /bin/sh` on the on-screen keyboard. The phone is
  `172.16.42.1`, but the host doesn't get a DHCP lease there, so assign one
  (runtime only, not saved):
  ```sh
  nmcli device modify enp10s0u2 ipv4.method manual ipv4.addresses 172.16.42.2/24
  nc 172.16.42.1 23        # or: telnet 172.16.42.1
  ```
  Read `/pmOS_init.log` and `/init_functions.sh` there.
- **Phone partition info from TWRP:** `ls -la /dev/block/mapper/`,
  `ls /dev/block/by-name/`, `cat /sys/block/dm-0/dm/name`. Read-only `dd | od`
  peeks at MBRs and ext4 magic (`53 ef` at offset 1080); remember sectors are
  4096 bytes.

## Upstreaming candidates

- pmaports: the gzip initfs patch (same as the other "specify gzip-ing initfs"
  commits). Taking over maintainership would un-archive the device.
- pmbootstrap: install cross binutils for clang builds.
- Recovery installer / initramfs: 4K-sector subpartition handling.
