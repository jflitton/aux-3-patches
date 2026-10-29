#!/bin/sh
# Build the DaynaPORT driver module from source (needs m68k-elf-gcc and m68k-elf-binutils):
#   patches/daynaport/build.sh KERNEL OUTDIR
# writes OUTDIR/dayna, the A/UX COFF module for /etc/boot.d/dayna. On the way:
#   build/daynaport/dayna.o   ELF relocatable (m68k-elf-ld -r with src/module.ld)
# The COFF is checked against the ELF (both linked at the same addresses, see
# tools/elf2coff.py verify), and every symbol it needs must be in KERNEL (an A/UX 3.1
# /unix), or the link into /unix would fail.
set -e
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
kernel=$(abs "$1") outdir=$(abs "$2")
cd "$(dirname "$0")/../.."
p=patches/daynaport b=build/daynaport
mkdir -p $b "$outdir"
py="python3 -I"
m68k-elf-gcc -m68020 -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic -fno-common \
	-fno-omit-frame-pointer -fno-jump-tables -fno-strict-aliasing -msoft-float \
	-Wall -Wno-unused-function -Werror -c $p/src/dayna.c -o $b/dayna-c.o
m68k-elf-ld -r -T $p/src/module.ld -o $b/dayna.o $b/dayna-c.o
$py tools/elf2coff.py $b/dayna.o "$outdir/dayna"
$py tools/elf2coff.py verify $b/dayna.o "$outdir/dayna"
$py tools/elf2coff.py undef "$outdir/dayna" "$kernel"
m68k-elf-size -A $b/dayna.o | grep -E '^\.(text|data|bss)'
