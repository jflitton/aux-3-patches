#!/bin/sh
# Build the q605 kernel patch from source (needs m68k-elf-gcc and m68k-elf-binutils):
#   patches/q605/build.sh KERNEL OUTDIR
# KERNEL is an A/UX 3.1 /unix. Links the Cuda transport (modules/cuda/cuda.c) and src/q605.S
# (the MEMCjr module, modules/memcjr) at cEgretDispatch and writes OUTDIR/kernel.txt, the
# binpatch spec; the intermediate files (.elf, and .bin .bin2 .bin3 for the raw .text .text2
# .text3) go in build/q605. CKPT=1 builds the checkpoint variant (see
# modules/common/hooks.S) as kernel-ckpt.txt.
set -e
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
kernel=$(abs "$1") outdir=$(abs "$2")
cd "$(dirname "$0")/../.."
p=patches/q605 b=build/q605
mkdir -p $b "$outdir"
python3 -I tools/ksyms-ld.py "$kernel" > $b/kernel.ld
python3 -I $p/kernel-patch.py "$kernel" ld > $b/hooks.ld
m68k-elf-gcc -m68040 -Os -ffreestanding -fno-builtin -nostdlib -fno-pic -fomit-frame-pointer \
	-fno-jump-tables -ffunction-sections -Wall -Werror -c modules/cuda/cuda.c -o $b/cuda.o
out=$b/kernel spec=$outdir/kernel.txt
defs=
if [ -n "$CKPT" ]; then out=$out-ckpt spec=$outdir/kernel-ckpt.txt defs=-DCKPT_BUILD; fi
m68k-elf-gcc -m68040 $defs -I modules -c $p/src/q605.S -o $b/q605.o
m68k-elf-ld -T $b/kernel.ld -T $b/hooks.ld -T $p/src/kernel.ld \
	-o $out.elf $b/cuda.o $b/q605.o
m68k-elf-objcopy -O binary -j .text $out.elf $out.bin
m68k-elf-objcopy -O binary -j .text2 $out.elf $out.bin2
m68k-elf-objcopy -O binary -j .text3 $out.elf $out.bin3
python3 -I $p/kernel-patch.py "$kernel" spec $out.elf $out.bin $out.bin2 $out.bin3 > "$spec"
m68k-elf-size -A $out.elf | grep text
m68k-elf-nm -n $out.elf | grep -i ' t '
