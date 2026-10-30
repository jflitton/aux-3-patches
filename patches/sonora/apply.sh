#!/bin/sh
# Sonora support (the LC III and LC III+, and the Performa 450, 460, 466 and 467), applied
# in place to an A/UX 3.1 disk image (use a copy: DISK is changed):
#   patches/sonora/apply.sh DISK System_Enabler_003_1.1.sea.bin
# DISK gets
#   - System Enabler 003 in the Mac OS System Folder (System 7.1 needs it on these Macs),
#   - the kernel patch on /unix and /etc/config.d/newunix (bin/kernel-sonora.txt),
#   - the Toolbox patch (src/toolbox-sonora.txt),
#   - the sound driver patch on /unix and /etc/boot.d/snd (src/snd-sonora.txt).
# CKPT=1 builds and uses the checkpoint kernel (see src/sonora.S) instead; that needs the
# m68k-elf toolchain.
set -e
if [ $# -ne 2 ]; then
	echo "usage: $0 DISK ENABLER" >&2
	exit 1
fi
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
disk=$(abs "$1") enabler=$(abs "$2")
cd "$(dirname "$0")/../.."
p=patches/sonora
py="python3 -I"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Mac OS: add the enabler. hfsutils rewrites whatever it mounts, so work on a dd copy of the
# HFS partition and put it back.
set -- $($py tools/ufs.py "$disk" find Apple_HFS)
hfs_start=$2 hfs_blocks=$3
# the resource fork as an AppleDouble file, NAME.rsrc, as unar writes it on Linux too
unar -q -k visible -o "$tmp/enabler" "$enabler"
set -- "$tmp"/enabler/*
if [ $# -ne 1 ]; then echo "expected one file in $enabler" >&2; exit 1; fi
$py tools/macbin.py "$1" "$tmp/enabler.bin" "System Enabler 003"
dd if="$disk" of="$tmp/hfs.img" bs=512 skip="$hfs_start" count="$hfs_blocks" 2>/dev/null
hmount "$tmp/hfs.img" >/dev/null
hcopy -m "$tmp/enabler.bin" ":System Folder:"
humount
dd if="$tmp/hfs.img" of="$disk" bs=512 seek="$hfs_start" conv=notrunc 2>/dev/null

# A/UX: kernel and Toolbox patches
root=$($py tools/ufs.py "$disk" find 'Root&Usr' | awk '{ print $1 }')
spec=$p/bin/kernel-sonora.txt
if [ -n "$CKPT" ]; then
	$py tools/ufs.py "$disk" cat "$root" /unix > "$tmp/unix"
	sh $p/build.sh "$tmp/unix" "$tmp" > /dev/null
	spec=$tmp/kernel-sonora-ckpt.txt
fi
$py tools/binpatch.py "$spec" "$disk" "$root" --apply
$py tools/binpatch.py $p/src/toolbox-sonora.txt "$disk" "$root" --apply
$py tools/binpatch.py $p/src/snd-sonora.txt "$disk" "$root" --apply
echo "$disk: Sonora support added"
