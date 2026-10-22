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
| Initramfs finds the subpartitions | works (installer patch, verified by a full install), see [Issue 8](#8-initramfs-cant-find-the-subpartitions-4k-sectors) |
| Initramfs mounts the root partition | works (initramfs patch), see [Issue 9](#9-initramfs-cant-mount-the-root-partition-direct-io-on-4k-storage) |
| System boots, SSH | works: Dropbear answers on `172.16.42.1:22` ~40 s after boot |
| SSH key login | works (needed home permission fix), see [After the first boot](#after-the-first-boot) |
| Wi-Fi | works on <SSID> (DHCP); static IP for the final location documented, see [Wi-Fi](#wi-fi) |
| DNS, screen off | not started yet |

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

# 4. build patched packages first: building them during the zip step hits a
#    pmbootstrap bug (buildroot zap drops the rootfs mount, then
#    "tar: /mnt/rootfs_samsung-a51: Cannot open"). Re-running also works.
pmbootstrap build postmarketos-initramfs --arch aarch64   # noarch: without --arch it lands in x86_64 only
pmbootstrap build postmarketos-android-recovery-installer --arch aarch64

# 5. build the TWRP zip, installing onto userdata
pmbootstrap install --android-recovery-zip --recovery-install-partition=userdata
kill %1

# 6. phone: TWRP > Advanced > ADB Sideload (leave wipe options unticked)
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

## After the first boot

### First login over USB

The phone is `172.16.42.1` on the USB network (`enp10s0u2` on the PC). If the
PC doesn't get a `172.16.42.x` address from the phone's DHCP within a minute,
set one (runtime only, gone after a replug):

```sh
nmcli device modify enp10s0u2 ipv4.method manual ipv4.addresses 172.16.42.2/24
ssh ahmed@172.16.42.1                      # password from pmbootstrap install
ssh-copy-id -i ~/.ssh/id_ed25519.pub ahmed@172.16.42.1
```

**Key login kept asking for the password:** the recovery installer creates
`/home/ahmed` itself, with ownership/permissions Dropbear rejects (it silently
ignores `authorized_keys` if the home or `~/.ssh` is writable by others). The
client log showed `id_ed25519` offered and refused. Fixed on the phone with:

```sh
sudo chown -R ahmed:ahmed ~
chmod 755 ~; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys
```

### Wi-Fi

Wi-Fi (Samsung `wlbt`/mx140 driver) works with the firmware package. The driver
finds no stored MAC (`/efs/wifi/.mac.info`, `mac.txt` missing) and uses a
random one, so pin a stable MAC per connection. Wi-Fi power saving causes
latency spikes (measured 1.7 ms to 152 ms ping to the phone), so turn it off.

`sudo` asks for the user password; run these in an SSH session yourself so the
Wi-Fi password doesn't end up in logs. Prefer the USB session (`172.16.42.1`)
when changing a connection, since the Wi-Fi IP may change.

**Temporary location (DHCP)**, tested 2026-10-22 on <SSID> (5 GHz):

```sh
sudo nmcli dev wifi connect <SSID> password 'WIFI_PASSWORD' name home-wifi
sudo nmcli con modify home-wifi \
  802-11-wireless.cloned-mac-address stable \
  802-11-wireless.powersave 2
sudo nmcli con up home-wifi
```

**Final location (static IP).** Find the new network's subnet, router and DHCP
range first (router admin page, or `ip route` on any machine there). Pick an
address outside the DHCP range, or reserve it in the router. The examples
assume `192.168.0.0/24` with the router at `192.168.0.1`; adjust:

```sh
# 1. connect (creates the profile and saves the password)
sudo nmcli dev wifi connect 'NEW_SSID' password 'WIFI_PASSWORD' name server-wifi

# 2. static IP, stable MAC, no power saving, always reconnect
sudo nmcli con modify server-wifi \
  ipv4.method manual \
  ipv4.addresses 192.168.0.53/24 \
  ipv4.gateway 192.168.0.1 \
  ipv4.dns "192.168.0.1 1.1.1.1" \
  ipv6.method auto \
  802-11-wireless.cloned-mac-address stable \
  802-11-wireless.powersave 2 \
  connection.autoconnect yes \
  connection.autoconnect-priority 10
sudo nmcli con up server-wifi

# 3. optional: stop the phone from joining the old network there
sudo nmcli con delete home-wifi
```

Check it:

```sh
nmcli -f NAME,DEVICE,STATE con show --active
ip -br a show wlan0; ip route           # static address, default via router
ping -c3 1.1.1.1; ping -c3 alpinelinux.org
iwconfig wlan0 | grep -i power         # "Power Management:off"
```

Notes:

- Once this phone runs the DNS server, don't list itself first in
  `ipv4.dns` until the server works; keep the router/1.1.1.1 so the phone can
  still resolve (e.g. for `apk`).
- To set up the new network before moving, the profile can be created without
  being in range: `sudo nmcli con add type wifi ifname wlan0 con-name
  server-wifi ssid 'NEW_SSID' wifi-sec.key-mgmt wpa-psk wifi-sec.psk
  'WIFI_PASSWORD'`, then run step 2 (skip `con up`). It connects automatically
  when the network is in range.
- If Wi-Fi is wrong and SSH over Wi-Fi is gone, plug in USB and use
  `ssh ahmed@172.16.42.1`.

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

Why the February installs (same 4K-unit table) booted: their initramfs mapped
subpartitions with **`kpartx`** (device-mapper), which honours the disk's real
sector size and does no direct I/O. Verified by extracting the initramfs from
the old zip. pmaports switched to loop devices in `86bdb82116` (2026-02-05,
"use loop device for subpartitions", MR 7932), noting "There *should* be no
impact to existing installs"; 4K-sector storage on an old kernel wasn't
covered. That one change causes both this issue and [Issue 9](#9-initramfs-cant-mount-the-root-partition-direct-io-on-4k-storage).

We chose to adapt the new loop logic (option B) instead of reverting the
initramfs to kpartx (option A): two small, generic patches versus reverting a
refactor that later commits build on. Option A remains the fallback.

**Fix:** `patches/pmaports/0002-recovery-installer-convert-4k-sector-table-to-512-byte-units.patch`.
It adds a patch to the `postmarketos-android-recovery-installer` package
(pkgrel 3). The installer still partitions with `parted` + `kpartx` directly
on the install partition (4K units, as before). Then, if
`blockdev --getss` reports more than 512, `convert_table_to_512_byte_units()`
multiplies both MBR entries' start and size by `sector_size / 512` in place
(`od` to read, `printf | dd conv=notrunc` to write). The byte offsets don't
change, so the kpartx mappings and the filesystems are unaffected, and the
initramfs' default `losetup -P` finds `pmOS_boot`/`pmOS_root`. The installer log
(`/tmp/postmarketos/pmos.log`) shows the conversion:

```
/dev/block/sda32 has 4096-byte sectors, converting its MBR to 512-byte units
partition 1: start 2048 -> 16384, size 60416 -> 483328
partition 2: start 62464 -> 499712, size 29110272 -> 232882176
```

**Failed first attempt (pkgrel 2):** partition through a 512-byte loop device
attached to `sda32`. In TWRP every loop read/write returned I/O errors:
TWRP's SELinux is enforcing and denies the kernel's loop thread access to block
devices (`avc: denied { read } for comm="loop1" ... tclass=blk_file
permissive=0`). This is also why read-only loop mounts of `sda32` failed in
TWRP with "Invalid argument". The pmOS initramfs has no SELinux, so loops work
there.

**One-off workaround for an existing install:** rewrite only the MBR of
`sda32` in 512-byte units with the same byte offsets (p1 start 16384,
p2 start 499712). Filesystems are untouched.

### 9. Initramfs can't mount the root partition (direct I/O on 4K storage)

With the 512-unit table the initramfs finds `/dev/loop0p2`, then:

```
Mount root partition (/dev/loop0p2) to /sysroot (read-write) with options
mount: mounting /dev/loop0p2 on /sysroot failed: Invalid argument
ERROR: unable to mount root partition!
```

`dmesg` shows the storage driver rejecting the loop's requests:

```
exynos-ufs 13520000.ufs: Invalid bio
print_req_error: I/O error, dev loop0, sector 499712
```

The initramfs attaches the loop with `--direct-io=on`. Direct I/O passes the
loop's 512-byte-granular requests straight to the UFS, which only accepts
4 KiB-aligned I/O. Live test in the debug shell on a fresh loop device:
without direct I/O ext4 mounts fine; with `--direct-io=on` it fails with
`unable to read superblock`. (Switching an existing loop to
`--direct-io=off` was not enough.)

**Fix:** `patches/pmaports/0003-initramfs-no-direct-io-for-mismatched-sector-size.patch`
(`postmarketos-initramfs` pkgrel 1). In `mount_subpartitions()`, direct I/O is
only used when `blockdev --getss` of the partition equals the loop's sector size
(512, or `deviceinfo_rootfs_image_sector_size`). Otherwise the initramfs log
shows `/dev/sda32 has 4096-byte sectors, loop has 512: not using direct I/O`.
Verified by copying the patched `init_functions.sh` into the debug shell and
running `mount_subpartitions`: it picked `/dev/loop0p2` without direct I/O and
`pmOS_root` mounted.

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
- Recovery installer: the 4K-sector patch.
- Initramfs: no direct I/O when sector sizes differ. It could also detect the
  mismatch itself (e.g. fall back to `kpartx`).
