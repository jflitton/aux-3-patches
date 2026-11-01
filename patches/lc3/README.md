# LC III

`--enabler System_Enabler_003_1.1.sea.bin` · A/UX 3.1 · LC III and LC III+ (and the
Performa 450, 460, 466 and 467) with an FPU; tested on an LC III running at 33 MHz

Runs A/UX 3.1 on the Macs built on Apple's Sonora chip with the Egret system controller:
the LC III and Performa 450, and the LC III+ and Performa 460, 466 and 467. A/UX knows
their hardware (a 68030 with Egret, a 5380 SCSI chip, built-in video with its own video
memory) from the Mac IIvx, but not the Macs themselves, and stops with "unsupported
motherboard type".

On an LC III running at 33 MHz (which identifies itself as an LC III+) with 36 MB, A/UX
starts up to its desktop with all its memory, video at 640×480 in thousands of colors
(768 KB of video memory) or 256 (512 KB), DaynaPORT networking, sound with a working
volume control, and shuts down and restarts. A 25 MHz LC III and the Performas have only
run it in the MAME emulator; if you try one, please open an issue saying how far it got.

It adds System Enabler 003 to the disk's Mac OS, sends these Macs down the kernel's IIvx
path, sizes their memory safely, sets up their sound hardware, and lets System 7.1 accept
them. Other Macs don't need it. A disk can have this patch or the Quadra 605 patch, not
both, and a disk with this patch is only for these Macs: it reuses space in the kernel that
the Quadras with Orwell and djMEMC memory controllers need.

## You need

- **An FPU.** These Macs have a socket for a 68882 floating-point unit, often empty, and
  A/UX requires one.
- **System Enabler 003** version 1.1, usually `System_Enabler_003_1.1.sea.bin` (widely
  archived online), as downloaded. Version 1.0 doesn't know the LC III+. Give it to
  `make-disk.sh` with `--enabler`, which picks this patch for it. (`--sonora`, this
  patch's old option, still works.)
- hfsutils and unar (on a Mac, `brew install hfsutils unar`).

## Compatibility

| | Tested | Not tested yet | Won't work |
|---|---|---|---|
| **Mac** | LC III at 33 MHz (reports itself as an LC III+); LC III and LC III+ in MAME | Performa 450, 460, 466, 467 | LC 520, LC 550, Color Classic II, Macintosh TV (Sonora, but with the Cuda controller) |
| **Processor** | 68030 with a 68882 | | No FPU |
| **Clock speed** | 33 MHz; 25 MHz in MAME | | |
| **Memory** | 36 MB; 32 MB in MAME, with 32-bit addressing off or on | Other amounts | |
| **Video memory** | 512 KB (up to 256 colors), 768 KB (thousands) | | |
| **A/UX disk** | `AUX_3_1_1GB_Use_In_Shoebill.zip` | Other A/UX 3.1 disks | |
| **With** | `--date`, `--daynaport` | | The Quadra 605 patch (System Enabler 065) |

Tested: starts up to the A/UX desktop with sound (every alert sound, and A/UX's volume
control), networking, shutting down and restarting. The floppy drive, the serial ports and
sound input are found by the kernel but haven't been tried.

## Troubleshooting

**A/UX Startup says "No FPU":** fit a 68882 in the FPU socket.

**"Command is respawning too rapidly" for `catsearchd`:** A/UX found less than 16 MB of
memory, the minimum its Find File daemon asks for. With this patch's first version that
happened even with more memory installed, if Mac OS had 32-bit addressing off; make a new
disk.

**The screen goes dark after "Launching…" and stays dark:** make a checkpoint disk, which
restarts the Mac (with the startup chime) at a point of your choosing, to find where it
stops. Build it with `CKPT=1 patches/lc3/apply.sh DISK ENABLER` on a copy of an A/UX
disk (this needs the m68k-elf cross compiler; see
[development.md](../../docs/development.md)). Then hold a digit key from "Launching…"
until the screen goes dark:

| Key | Restarts once the kernel has | Key | Restarts once the kernel has |
|---|---|---|---|
| 1 | started | 6 | set up the Egret (clock, PRAM) |
| 2 | identified the Mac | 7 | set up the video |
| 3 | sized the memory | 8 | set up the keyboard and mouse |
| 4 | turned on the memory management unit | 9 | started its drivers (SCSI) |
| 5 | set up the VIAs | 0 | mounted the A/UX disk |

The highest key that still restarts the Mac tells where it stops. Restarting after key 0
leaves the disk to be checked at the next start ("Checking…"); that is expected.

## For developers

| File | What it is |
|---|---|
| `apply.sh DISK ENABLER` | Applies the patch to a copy of a disk image |
| `build.sh KERNEL OUTDIR` | Builds `bin/` from `src/` and the modules (needs the m68k-elf cross compiler) |
| `kernel-patch.py` | Finds the places to change in an A/UX kernel; writes the kernel patch |
| `src/lc3.S` | The kernel hooks: which Macs these are (`IFOURMAC`), then the modules below |
| `src/kernel.ld` | Links them into the space of `orwellsize` and `memcdjsize` |
| `src/toolbox.txt` | Byte patch to the Toolbox (`Patch.067C`): the LC III's and LC III+'s BoxFlags |
| `src/snd.txt` | Byte patch to the sound driver (`/unix` and `/etc/boot.d/snd`): samples to both sound FIFOs |
| `bin/kernel.txt` | The kernel patch, for `/unix` and `/etc/config.d/newunix` |
| `../../modules/sonora/sonora.S` | The Sonora board module: `boardinit`'s switch, RAM sizing, interrupt vectors, `_EgretDispatch`'s result, the sound chip type and the DFAC (sound output); `ourmac`, the test for these Macs |
| `../../modules/common/hooks.S` | Hooks the board modules share, and the checkpoint code |

Notes: [docs/findings.md](../../docs/findings.md).
