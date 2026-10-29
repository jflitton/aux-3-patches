#!/bin/sh
# MEMCjr support (the Quadra 605; the LC/Performa 475, untested), applied in place to an
# A/UX 3.1 disk image (use a copy: DISK is changed):
#   patches/memcjr/apply.sh DISK System_Enabler_065_12-sea.bin
# DISK gets
#   - System Enabler 065 in the Mac OS System Folder (System 7.1 needs it on these Macs),
#   - the kernel patch on /unix and /etc/config.d/newunix (bin/kernel-605.txt),
#   - the Toolbox patch (src/toolbox-605.txt).
# CKPT=1 builds and uses the checkpoint kernel (see src/boot605.S) instead; that needs the
# m68k-elf toolchain.
set -e
if [ $# -ne 2 ]; then
	echo "usage: $0 DISK ENABLER" >&2
	exit 1
fi
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
disk=$(abs "$1") enabler=$(abs "$2")
cd "$(dirname "$0")/../.."
p=patches/memcjr
py="python3 -I"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Mac OS: add the enabler. hfsutils rewrites whatever it mounts, so work on a dd copy of the
# HFS partition and put it back.
set -- $($py tools/ufs.py "$disk" find Apple_HFS)
hfs_start=$2 hfs_blocks=$3
unar -q -o "$tmp/enabler" "$enabler"
set -- "$tmp"/enabler/*
if [ $# -ne 1 ]; then echo "expected one file in $enabler" >&2; exit 1; fi
$py tools/macbin.py "$1" "$tmp/enabler.bin" "System Enabler 065"
dd if="$disk" of="$tmp/hfs.img" bs=512 skip="$hfs_start" count="$hfs_blocks" 2>/dev/null
hmount "$tmp/hfs.img" >/dev/null
hcopy -m "$tmp/enabler.bin" ":System Folder:"
humount
dd if="$tmp/hfs.img" of="$disk" bs=512 seek="$hfs_start" conv=notrunc 2>/dev/null

# A/UX: kernel and Toolbox patches
root=$($py tools/ufs.py "$disk" find 'Root&Usr' | awk '{ print $1 }')
spec=$p/bin/kernel-605.txt
if [ -n "$CKPT" ]; then
	$py tools/ufs.py "$disk" cat "$root" /unix > "$tmp/unix"
	sh $p/build.sh "$tmp/unix" "$tmp" > /dev/null
	spec=$tmp/kernel-605-ckpt.txt
fi
$py tools/binpatch.py "$spec" "$disk" "$root" --apply
$py tools/binpatch.py $p/src/toolbox-605.txt "$disk" "$root" --apply
echo "$disk: MEMCjr support added"
