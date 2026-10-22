#!/bin/sh
# Apply our local fixes to the pmbootstrap and pmaports checkouts.
# Safe to re-run: patches that are already applied are skipped.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

apply_dir() {
	repo="$1"
	patches="$2"
	[ -d "$repo/.git" ] || { echo "ERROR: $repo is not a git checkout"; exit 1; }
	for p in "$patches"/*.patch; do
		[ -e "$p" ] || continue
		name="$(basename "$p")"
		if git -C "$repo" apply --check -R "$p" 2>/dev/null; then
			echo "  already applied: $name"
		elif git -C "$repo" apply --check "$p" 2>/dev/null; then
			git -C "$repo" apply "$p"
			echo "  applied:         $name"
		else
			echo "ERROR: $name does not apply to $repo (upstream changed?)"
			exit 1
		fi
	done
}

echo "pmbootstrap:"
apply_dir "$ROOT/pmbootstrap" "$ROOT/patches/pmbootstrap"
echo "pmaports:"
apply_dir "$ROOT/cache_git/pmaports" "$ROOT/patches/pmaports"
