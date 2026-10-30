#!/bin/sh
# Bring bin/ up to date from an aux-3-pkg checkout (https://github.com/jflitton/aux-3-pkg),
# building pkg there with its own Makefile (needs m68k-elf-gcc and m68k-elf-binutils):
#   patches/pkg/update.sh AUX-PKG
# writes bin/pkg, the A/UX executable, and bin/record, the start of the record pkg keeps
# of itself on the Mac: its version, and the aux-3-pkg tag or commit it was built from. The
# checkout must have no uncommitted changes, so that bin/record says what's in bin/pkg.
set -e
if [ $# -ne 1 ]; then
	echo "usage: $0 AUX-PKG" >&2
	exit 1
fi
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
src=$(abs "$1")
cd "$(dirname "$0")"
if [ -n "$(git -C "$src" status --porcelain)" ]; then
	echo "$src has uncommitted changes" >&2
	exit 1
fi
make -C "$src" build/aux/pkg
version=$(sed -n 's/^#define[ 	]*PKG_VERSION[ 	]*"\(.*\)"/\1/p' "$src/src/pkg.h")
[ -n "$version" ] || { echo "no PKG_VERSION in $src/src/pkg.h" >&2; exit 1; }
built=$(git -C "$src" describe --tags --always)
mkdir -p bin
cp "$src/build/aux/pkg" bin/pkg
cat > bin/record <<EOF
format 1
name pkg
version $version
summary Installs, upgrades and removes packages
url https://github.com/jflitton/aux-3-pkg
built $built
EOF
echo "bin/pkg: pkg $version, built from aux-3-pkg $built"
