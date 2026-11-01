#!/bin/sh
# Build the lc3 kernel patch from source (needs m68k-elf-gcc and m68k-elf-binutils):
#   patches/lc3/build.sh KERNEL OUTDIR
# KERNEL is an A/UX 3.1 /unix. Links src/lc3.S (the Sonora module, modules/sonora) at
# orwellsize and writes OUTDIR/kernel.txt, the binpatch spec; the intermediate files (.elf,
# and .bin for the raw .text) go in build/lc3. CKPT=1 builds the checkpoint variant (see
# modules/common/hooks.S) as kernel-ckpt.txt.
set -e
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
kernel=$(abs "$1") outdir=$(abs "$2")
cd "$(dirname "$0")/../.."
p=patches/lc3 b=build/lc3
mkdir -p $b "$outdir"
python3 -I tools/ksyms-ld.py "$kernel" > $b/kernel.ld
python3 -I $p/kernel-patch.py "$kernel" ld > $b/hooks.ld
out=$b/kernel spec=$outdir/kernel.txt
defs=
if [ -n "$CKPT" ]; then out=$out-ckpt spec=$outdir/kernel-ckpt.txt defs=-DCKPT_BUILD; fi
m68k-elf-gcc -m68030 $defs -I modules -c $p/src/lc3.S -o $out.o
m68k-elf-ld -T $b/kernel.ld -T $b/hooks.ld -T $p/src/kernel.ld -o $out.elf $out.o
m68k-elf-objcopy -O binary -j .text $out.elf $out.bin
python3 -I $p/kernel-patch.py "$kernel" spec $out.elf $out.bin > "$spec"
m68k-elf-size -A $out.elf | grep text
m68k-elf-nm -n $out.elf | grep -i ' t '
