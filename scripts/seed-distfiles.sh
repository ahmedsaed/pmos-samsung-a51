#!/bin/sh
# Pre-seed pmbootstrap's source cache (cache_distfiles) so builds don't depend
# on flaky upstream hosts. Every file is verified against the sha512sums in the
# APKBUILD before it is installed, so a wrong file can't slip through.
#
# Usage: scripts/seed-distfiles.sh [old-pmos-samsung-a51.zip]
#   The zip (any earlier pmOS recovery zip for this device) is used as the
#   source of the Wi-Fi firmware, because dumps.tadiphone.dev is down.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/cache_distfiles"
PMAPORTS="$ROOT/cache_git/pmaports/device/archived"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# expected_sum <APKBUILD> <distfile name>
expected_sum() {
	grep "  $2\$" "$1" | cut -d' ' -f1
}

# install_verified <APKBUILD> <local file> <distfile name>
install_verified() {
	want="$(expected_sum "$1" "$3")"
	have="$(sha512sum "$2" | cut -d' ' -f1)"
	if [ "$want" != "$have" ]; then
		echo "ERROR: checksum mismatch for $3"
		exit 1
	fi
	sudo install -m 664 -o root -g 300 "$2" "$DIST/$3"
	echo "  ok: $3"
}

# Kernel source (GitHub)
APK="$PMAPORTS/linux-samsung-a51/APKBUILD"
C="$(sed -n 's/^_commit="\(.*\)"/\1/p' "$APK")"
F="linux-samsung-a51-$C.tar.gz"
if [ ! -e "$DIST/$F" ]; then
	echo "Downloading kernel source..."
	curl -fL --retry 3 -o "$TMP/$F" \
		"https://github.com/manoedinata/android_kernel_samsung_a51/archive/$C.tar.gz"
	install_verified "$APK" "$TMP/$F" "$F"
fi

# Wi-Fi firmware (dumps.tadiphone.dev is down; extract from an old zip)
APK="$PMAPORTS/firmware-samsung-a51/APKBUILD"
C="$(sed -n 's/^_commit="\(.*\)"/\1/p' "$APK")"
if [ ! -e "$DIST/firmware-samsung-a51-$C-mx140.bin" ]; then
	ZIP="${1:-}"
	[ -n "$ZIP" ] || { echo "ERROR: firmware missing; pass an old pmOS zip"; exit 1; }
	echo "Extracting firmware from $ZIP..."
	unzip -q -o "$ZIP" rootfs.tar.gz -d "$TMP"
	tar -xzf "$TMP/rootfs.tar.gz" -C "$TMP" \
		./lib/firmware/postmarketos/samsung-a51/mx140/
	for f in mx mx140.bin mx140_wlan.hcf mx140_wlan_sw.hcf; do
		install_verified "$APK" \
			"$TMP/lib/firmware/postmarketos/samsung-a51/mx140/$f" \
			"firmware-samsung-a51-$C-$f"
	done
fi
echo "Done."
