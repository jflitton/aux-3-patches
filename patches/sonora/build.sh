#!/bin/sh
# Build the Sonora kernel patch from source (needs m68k-elf-gcc and m68k-elf-binutils):
#   patches/sonora/build.sh KERNEL OUTDIR
# KERNEL is an A/UX 3.1 /unix. Links src/sonora.S at orwellsize and writes
# OUTDIR/kernel-sonora.txt, the binpatch spec; the intermediate files (.elf, and .bin for
# the raw .text) go in build/sonora. CKPT=1 builds the checkpoint variant (see
# src/sonora.S) as kernel-sonora-ckpt.txt.
set -e
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
kernel=$(abs "$1") outdir=$(abs "$2")
cd "$(dirname "$0")/../.."
p=patches/sonora b=build/sonora
mkdir -p $b "$outdir"
python3 -I tools/ksyms-ld.py "$kernel" > $b/kernel.ld
python3 -I $p/kernel-patch.py "$kernel" ld > $b/hooks.ld
out=$b/kernel-sonora spec=$outdir/kernel-sonora.txt
defs=
if [ -n "$CKPT" ]; then out=$out-ckpt spec=$outdir/kernel-sonora-ckpt.txt defs=-DCKPT_BUILD; fi
m68k-elf-gcc -m68030 $defs -c $p/src/sonora.S -o $out.o
m68k-elf-ld -T $b/kernel.ld -T $b/hooks.ld -T $p/src/sonora.ld -o $out.elf $out.o
m68k-elf-objcopy -O binary -j .text $out.elf $out.bin
python3 -I $p/kernel-patch.py "$kernel" spec $out.elf $out.bin > "$spec"
m68k-elf-size -A $out.elf | grep text
m68k-elf-nm -n $out.elf | grep -i ' t '
