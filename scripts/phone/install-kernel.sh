#!/bin/sh
# Install locally built kernel/device packages and flash the new boot.img.
# Usage: sudo sh ~/install-kernel.sh ~/linux-samsung-a51-<ver>.apk [more.apk ...]
set -eu
[ $# -ge 1 ] || { echo "usage: $0 package.apk [package.apk ...]"; exit 1; }
boot_part=/dev/disk/by-partlabel/boot

# Back up the current boot partition (restore from TWRP if the new one fails)
dd if="$boot_part" of=/home/ahmed/boot-backup.img bs=1M 2>/dev/null
echo "backed up boot partition to /home/ahmed/boot-backup.img"

apk add --allow-untrusted "$@"

# A leftover pmbootstrap marker makes mkinitfs skip silently
rm -f /in-pmbootstrap
before=$(date +%s)
mkinitfs >/dev/null
mtime=$(stat -c %Y /boot/boot.img)
if [ "$mtime" -lt "$before" ]; then
	echo "ERROR: /boot/boot.img was not regenerated, not flashing"
	exit 1
fi
grep -a -o -m1 "Linux version [^(]*([^)]*) ([^)]*) #[0-9]*-postmarketOS SMP PREEMPT [A-Za-z]* [A-Za-z]* [0-9]* [0-9:]*" /boot/boot.img | head -1

dd if=/boot/boot.img of="$boot_part" bs=1M 2>/dev/null
sync
echo "flashed. Reboot with: sudo reboot"
