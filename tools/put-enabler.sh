#!/bin/sh
# Put a System Enabler, as downloaded, into the Mac OS System Folder of an A/UX disk image
# (use a copy: DISK is changed):
#   tools/put-enabler.sh DISK ENABLER
# It goes in as "System Enabler NNN", NNN its number (tools/enabler.py). hfsutils rewrites
# whatever it mounts, so this works on a dd copy of the HFS partition and puts it back.
# Needs hfsutils and unar.
set -e
if [ $# -ne 2 ]; then
	echo "usage: $0 DISK ENABLER" >&2
	exit 1
fi
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
disk=$(abs "$1") enabler=$(abs "$2")
cd "$(dirname "$0")/.."
py="python3 -I"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

set -- $($py tools/ufs.py "$disk" find Apple_HFS)
hfs_start=$2 hfs_blocks=$3
# the resource fork as an AppleDouble file, NAME.rsrc, as unar writes it on Linux too
unar -q -k visible -o "$tmp/enabler" "$enabler"
set -- "$tmp"/enabler/*
if [ $# -ne 1 ]; then echo "expected one file in $enabler" >&2; exit 1; fi
number=$($py tools/enabler.py "$1" | cut -d' ' -f1)
if [ "$number" = - ]; then name=$(basename "$1" .rsrc); else name="System Enabler $number"; fi
$py tools/macbin.py "$1" "$tmp/enabler.bin" "$name"
dd if="$disk" of="$tmp/hfs.img" bs=512 skip="$hfs_start" count="$hfs_blocks" 2>/dev/null
hmount "$tmp/hfs.img" >/dev/null
hcopy -m "$tmp/enabler.bin" ":System Folder:"
humount
dd if="$tmp/hfs.img" of="$disk" bs=512 seek="$hfs_start" conv=notrunc 2>/dev/null
echo "$disk: $name added to the System Folder"
