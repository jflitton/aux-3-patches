#!/bin/sh
# Bring bin/netsetup-VERSION.pkg, the netsetup package this patch installs, up to date from
# an aux-3-ports checkout (https://github.com/jflitton/aux-3-ports), building it there with
# its own Makefile (needs m68k-elf-gcc and m68k-elf-binutils, and aux-3-pkg beside it):
#   patches/daynaport/update-netsetup.sh AUX-3-PORTS
# The checkout must have no uncommitted changes, so that the package is what's in its git.
set -e
if [ $# -ne 1 ]; then
	echo "usage: $0 AUX-3-PORTS" >&2
	exit 1
fi
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
src=$(abs "$1")
cd "$(dirname "$0")"
if [ -n "$(git -C "$src" status --porcelain)" ]; then
	echo "$src has uncommitted changes" >&2
	exit 1
fi
version=$(sed -n 's/^version //p' "$src/ports/netsetup/+PKG")
[ -n "$version" ] || { echo "no version in $src/ports/netsetup/+PKG" >&2; exit 1; }
make -C "$src" port-netsetup
mkdir -p bin
rm -f bin/netsetup-*.pkg
cp "$src/build/packages/netsetup-$version.pkg" bin/
echo "bin/netsetup-$version.pkg, built from aux-3-ports $(git -C "$src" describe --always)"
