#!/bin/sh
# Rebuild every patch's bin/ from its src/ (needs m68k-elf-gcc and m68k-elf-binutils):
#   tools/build-patches.sh AUX_3_1_1GB.dsk [--check]
# Runs each patches/NAME/build.sh KERNEL OUTDIR against the image's /unix (A/UX 3.1's own)
# and copies what it makes into patches/NAME/bin. With --check nothing is written: exit 1
# if any file in a bin/ differs from a fresh build.
set -e
cd "$(dirname "$0")/.."
img=$1 check=$2
py="python3 -I"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root=$($py tools/ufs.py "$img" find 'Root&Usr' | awk '{ print $1 }')
$py tools/ufs.py "$img" cat "$root" /unix > "$tmp/unix"
status=0
for build in patches/*/build.sh; do
	p=$(dirname "$build") name=$(basename "$(dirname "$build")")
	sh "$build" "$tmp/unix" "$tmp/$name" > /dev/null
	for f in "$tmp/$name"/*; do
		bin=$p/bin/$(basename "$f")
		if [ "$check" = --check ]; then
			cmp -s "$f" "$bin" && echo "$bin: up to date" || { echo "$bin: out of date"; status=1; }
		else
			mkdir -p "$p/bin"
			cp "$f" "$bin"
			echo "$bin: written"
		fi
	done
done
exit $status
