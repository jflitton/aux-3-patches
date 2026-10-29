# Developing the A/UX 3 patches

This is for changing a patch, adding one, rebuilding the `bin/` files, or testing in
emulators. To just make a disk, follow the [README](../README.md).

Technical notes: [findings.md](findings.md) (how A/UX boots, and how the MEMCjr support
came together) and [patches/daynaport/NOTES.md](../patches/daynaport/NOTES.md) (the
network driver, and linking it into `/unix`).

## Layout

| Path | What |
|---|---|
| `make-disk.sh` | The script for users: checks its inputs, copies the disk, runs the chosen patches' `apply.sh`, checks the result |
| `patches/NAME/` | One folder per patch (below) |
| `tools/` | Tools the patches share, the build-all script, and emulator helpers (below) |
| `docs/` | This guide and `findings.md` |
| `build/` | Intermediate build files (ignored by git) |

Each patch folder holds:

| File | What |
|---|---|
| `README.md` | For users: what the patch does, what it needs, what it was tested on, troubleshooting; and a table of the folder's files |
| `apply.sh DISK ...` | Applies the patch in place to a disk image. Only ever give it a copy |
| `src/` | What we write: source code, and byte patches written by hand |
| `build.sh KERNEL OUTDIR` | Builds `bin/` from `src/` against an A/UX `/unix` (only patches with something to compile) |
| `bin/` | What `build.sh` makes, committed so users need no 68k compiler |

| Patch | Option | Applied by `apply.sh` |
|---|---|---|
| `memcjr` | `--memcjr ENABLER` | System Enabler 065 into the Mac OS System Folder (on a `dd` copy of the HFS partition, as hfsutils rewrites whatever it mounts); `bin/kernel-605.txt` on `/unix` and on `/etc/config.d/newunix`, which autoconfig links new kernels from; `src/toolbox-605.txt` |
| `date` | `--date` | `src/date-y2k.txt` on `/bin/date` |
| `daynaport` | `--daynaport` | `bin/dayna` linked into `/unix` by `tools/linkmod.py` as autoconfig would, and in `/etc/boot.d` with `src/master` for autoconfig's own relinks; `src/startup`, `src/dpsetup`; given an IP address, `/etc/NETADDRS` and `/etc/resolv.conf` |

`make-disk.sh` applies them in that order and then checks the A/UX file system like fsck
would (`tools/ufsput.py DISK PART check`). The kernel patch and the driver are
independent: the patch only changes bytes in the core kernel, and the driver is linked
after it. On the Shoebill image, partition 5 is the A/UX root.

Byte patches (`*.txt` specs, applied by `tools/binpatch.py`) never contain Apple bytes.
Each site holds a checksum of the original bytes and our replacement, so a spec applies
only to the files it was written for. `tools/binpatch.py` only verifies unless given
`--apply`.

## Building `bin/`

The `bin/` files are built against the A/UX 3.1 `/unix` from `AUX_3_1_1GB.dsk`. The
MEMCjr kernel patch only touches the core kernel, which is the same in every A/UX 3.1
configuration, so it applies to any 3.1 `/unix`. The builds are reproducible. After
changing a `src/`:

    tools/build-patches.sh AUX_3_1_1GB.dsk            # rebuild every bin/
    tools/build-patches.sh AUX_3_1_1GB.dsk --check    # are they current?

## Adding a patch

1. Make `patches/NAME/`. Put what you write in `src/`: byte changes to existing files as a
   spec (see the format at the top of `tools/binpatch.py`), new files to install, source
   code. New files go on the disk with `tools/ufsput.py`, new kernel modules with
   `tools/linkmod.py`.
2. If anything needs compiling, add `build.sh KERNEL OUTDIR` writing it to `OUTDIR`, like
   the others; `tools/build-patches.sh` then builds it into `bin/`.
3. Add `apply.sh DISK ...`, which applies the patch in place, like the others.
4. In `make-disk.sh`, add the patch to `PATCHES` (in the order patches are applied), give
   it an option in the argument loop and the usage text, and define `NEEDS_NAME`,
   `title_NAME`, `check_NAME` and `apply_NAME`. The comment above `PATCHES` says what each
   one does. `check_NAME` should die with a plain message if the disk isn't one the patch
   was written for (binpatch without `--apply` is a good test).
5. Write `patches/NAME/README.md` (what it does, what it needs, what it has been tested on,
   troubleshooting, the folder's files), and add a row for it to the table of patches in
   the top-level README.

## Setup

    brew install m68k-elf-binutils m68k-elf-gcc hfsutils unar   # building
    brew install mame qemu                                      # emulators
    python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

The tools run on the system `python3` (3.9 or later) with only the standard library, as
`python3 -I tools/NAME.py`. The venv is for `tools/auxdis.py`, which needs capstone.

## Rules

- `build/` is ignored because its outputs embed ROM and kernel bytes. Never commit them,
  or any Apple file. A `bin/` holds only what's built from our own source.
- Boot only throwaway copies of disk images (`cp -c` on APFS); emulators write to them.
- Never `--apply` a patch to original media. `hmount` rewrites the volume header even for
  read-only commands, so only mount `dd` copies.

## Tools

| Path | What |
|---|---|
| `tools/build-patches.sh` | Rebuild or check every patch's `bin/` |
| `tools/binpatch.py` | Apply a patch spec to a file, or to files inside a disk image (clones only) |
| `tools/linkmod.py` | Link a `boot.d` module into a configured `/unix` as autoconfig would; `check` proves it on Apple's own |
| `tools/elf2coff.py` | Turn an `m68k-elf-ld -r` object into an A/UX COFF module; check it |
| `tools/ufsput.py` | Write files (up to 16MB) into an A/UX UFS partition (clones only); check a partition like fsck |
| `tools/ufs.py` | Read-only A/UX UFS reader (partitions, find, ls with device numbers, cat, extract, where) |
| `tools/macbin.py` | Wrap a macOS file with resource fork as MacBinary II (for `hcopy -m`) |
| `tools/coff.py`, `tools/auxdis.py` | A/UX COFF reader; symbol-annotated 68040 disassembler |
| `tools/ksyms-ld.py` | Kernel COFF symbols as a GNU ld script |
| `tools/mame-605-probe.lua` | MAME autoboot script: tracing, plus the older in-RAM kernel patches (see header) |
| `tools/cuda-mame-patch.py`, `tools/prodinfo-copy.py` | Inputs for the probe's in-RAM patch modes (superseded by the real patch) |
| `tools/probe-log.py` | Render a probe log: console text, exec/exit, panic strings |
| `tools/mame-snap.lua`, `tools/qemu-shots.py` | Periodic screenshots from MAME / QEMU q800 |
| `tools/mame-ckpt-test.lua` | Hold a checkpoint key (1-9, 0, Q-P) into a checkpoint kernel (`CKPT=1` build) and log restarts |

## Testing in MAME

MAME's `macqd605` is a 25 MHz 605. It has no DaynaPORT, so the driver reports none.

    cp -c OUT.hda CLONE.hd
    mame macqd605 -ram 128M -hard CLONE.hd -autoboot_script tools/mame-snap.lua \
      -snapshot_directory DIR -video none -sound none -nothrottle -seconds_to_run 170

With `mame-snap.lua`, `CPUID=2226 mame ...` makes it a 33 MHz 605, and `CPUID=2221` or
`2222` an LC/Performa 475 at 25 or 33 MHz. That is the only way to run the 475 with a full
68040: MAME's own `maclc475` has a 68LC040.

For a console log, run the probe instead: `OUT=log STOP=200 PATCHED=1 EXECLOG=1 mame ...
-debug -debugger none -autoboot_script tools/mame-605-probe.lua`, then
`python3 -I tools/probe-log.py KERNEL log`. `CKPT=1 patches/memcjr/apply.sh CLONE.hd
ENABLER` puts in a checkpoint kernel (see `patches/memcjr/src/boot605.S`) for finding hangs
on real hardware without a console.

## By hand

The `apply.sh` scripts work on any copy:

    cp -c AUX_3_1_1GB.dsk CLONE.hd
    patches/memcjr/apply.sh CLONE.hd System_Enabler_065_12-sea.bin
    patches/date/apply.sh CLONE.hd
    patches/daynaport/apply.sh CLONE.hd 192.168.1.50
    python3 -I tools/ufsput.py CLONE.hd 5 check
