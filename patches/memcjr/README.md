# MEMCjr

`--memcjr ENABLER` · A/UX 3.1 · Quadra 605 with a full 68040; LC 475 and Performa 475/476
untested

Runs A/UX 3.1 on the Quadra 605, whose MEMCjr memory and video controller and Cuda system
controller A/UX doesn't know, and in theory on the LC 475 and Performa 475/476. The LC 575
family, also MEMCjr Macs, isn't supported yet.

**The 475 is untested.** The Mac's ROM describes the 475 exactly as it does the 605 except
for the model and CPU ID numbers, so the patch treats a 475 as a 605. It has only run in
MAME, on a Quadra 605 made to report a 475's CPU ID; no real 475 has run it yet. If you try
one, please open an issue saying how far it got.

It adds System Enabler 065 to the disk's Mac OS, teaches the kernel the 605's Cuda
(keyboard, mouse, clock, power), memory and video, and lets System 7.1 accept the 605 and
475. Other Macs don't need it.

## You need

- **A full 68040.** The 605 and 475 came with a 68LC040 (marked *MC68LC040*), which lacks
  the floating-point unit A/UX requires.
- **System Enabler 065** version 1.2, usually `System_Enabler_065_12-sea.bin` (widely
  archived online), as downloaded.
- `brew install hfsutils unar`.

## Compatibility

| | Tested | Not tested yet | Won't work |
|---|---|---|---|
| **Mac** | Quadra 605 | LC 475, Performa 475 and 476 (work in MAME) | LC 575 family (not supported yet) |
| **Processor** | Full 68040 | | 68LC040 |
| **Clock speed** | 33 MHz | 25 MHz, the standard 605 (works in MAME) | |
| **Memory** | 132 MB | Other amounts | |
| **Video memory** | 1 MB | 512 KB, the 605's standard amount | |
| **A/UX disk** | `AUX_3_1_1GB_Use_In_Shoebill.zip` | Other A/UX 3.1 disks | |

Tested: starts up to the A/UX desktop, with video at every color depth.

## Troubleshooting

**A/UX Startup won't launch A/UX:** the processor is a 68LC040.

## For developers

| File | What it is |
|---|---|
| `apply.sh DISK ENABLER` | Applies the patch to a copy of a disk image |
| `build.sh KERNEL OUTDIR` | Builds `bin/` from `src/` (needs the m68k-elf cross compiler) |
| `kernel-patch.py` | Finds the places to change in an A/UX kernel; writes the kernel patch |
| `src/cuda.c` | Cuda transport for A/UX's Egret driver |
| `src/boot605.S` | Kernel boot hooks: `boardinit`, `devices[]`, `cpuspeed`, ProductInfo, RAM sizing; `ismemcjr`, the test for a 605 or 475 |
| `src/kernel605.ld` | Links both into the space of A/UX's Egret code |
| `src/toolbox-605.txt` | Byte patch to the Toolbox (`Patch.067C`): the 605's and 475's BoxFlags |
| `bin/kernel-605.txt` | The kernel patch, for `/unix` and `/etc/config.d/newunix` |

`CKPT=1 apply.sh …` installs a checkpoint kernel for locating hangs (see `src/boot605.S`).
Notes: [docs/findings.md](../../docs/findings.md).
