#!/bin/sh
# LC III and LC III+ support (and the Performa 450, 460, 466 and 467), applied in place to
# an A/UX 3.1 disk image (use a copy: DISK is changed):
#   patches/lc3/apply.sh DISK System_Enabler_003_1.1.sea.bin
# DISK gets
#   - System Enabler 003 in the Mac OS System Folder (System 7.1 needs it on these Macs),
#   - the kernel patch on /unix and /etc/config.d/newunix (bin/kernel.txt),
#   - the Toolbox patch (src/toolbox.txt),
#   - the sound driver patch on /unix and /etc/boot.d/snd (src/snd.txt).
# CKPT=1 builds and uses the checkpoint kernel (see modules/common/hooks.S) instead; that
# needs the m68k-elf toolchain.
set -e
if [ $# -ne 2 ]; then
	echo "usage: $0 DISK ENABLER" >&2
	exit 1
fi
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
disk=$(abs "$1") enabler=$(abs "$2")
cd "$(dirname "$0")/../.."
p=patches/lc3
py="python3 -I"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sh tools/put-enabler.sh "$disk" "$enabler"

root=$($py tools/ufs.py "$disk" find 'Root&Usr' | awk '{ print $1 }')
spec=$p/bin/kernel.txt
if [ -n "$CKPT" ]; then
	$py tools/ufs.py "$disk" cat "$root" /unix > "$tmp/unix"
	sh $p/build.sh "$tmp/unix" "$tmp" > /dev/null
	spec=$tmp/kernel-ckpt.txt
fi
$py tools/binpatch.py "$spec" "$disk" "$root" --apply
$py tools/binpatch.py $p/src/toolbox.txt "$disk" "$root" --apply
$py tools/binpatch.py $p/src/snd.txt "$disk" "$root" --apply
echo "$disk: LC III and LC III+ support added"
