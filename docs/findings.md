# A/UX on the Quadra 605 and LC III: findings (2026-10-28)

*Developer notes. To make a disk, see the [README](../README.md); for working on the code,
[development.md](development.md). This is a dated log, and files have moved since: the
605 work is now the MEMCjr patch, in `patches/memcjr/` (`src/` was `src/`, the build was
`tools/build-kernel605.sh`, and `tools/make-605-disk.sh` became `make-disk.sh --memcjr
--date`); `patches/date-y2k.txt` is `patches/date/src/date-y2k.txt`. Since 2026-11-01 the
MEMCjr and Sonora patches are `patches/q605/` and `patches/lc3/`, chosen by `make-disk.sh
--enabler`, and their code is in `modules/`: `boot605.S` is `modules/memcjr/memcjr.S`,
`src/cuda.c` `modules/cuda/cuda.c`, `sonora.S` `modules/sonora/sonora.S` (see that day's
section).*

Ground truth from disassembling the shipped kernels, plus MAME and Linux sources.
This supersedes the guesses in `reference/605-port-references.md` where they disagree.

Paths below are relative to the workspace: the directory that holds this `aux605/` repo
alongside the Apple media, extractions, ROMs and reference material (none of which is in
the repo).

## Workspace layout
| Path | What |
|---|---|
| `Apple AUX 3.0.1/` | Original media: A/UX 3.0.1 CD (APM: HFS "A/UX CDInstall" + 3 UFS partitions), install boot floppy (DiskCopy 4.2). |
| `Apple AUX 3.1 (Update)/` | Actually the **"AWS 95 Software Upgrade"** CD = A/UX **3.1** (RELEASE_ID: Feb 25 1994) delta over 3.0.1, incl. a 3.1 `newunix`, `launch`, Toolbox patches. |
| `extracted/` | Read-only extractions (Apple copyrighted, never redistribute). `aux-3.0.1-cd/part6` = installable root, `part4` = CD's own boot root, `aws95-upgrade/root` = 3.1 delta. |
| `refs/` | Third-party sources: `mame/` (macquadra605, djmemc/MEMCjr, iosb/PrimeTime, dafb, cuda, egret), `linux/` (config.c, via-cuda.c, mac_esp.c, macfb.c, via.c), `shoebill/`. |
| `aux605/` | **Git repo, our code only** (see its README): `src/` Cuda transport; `tools/` UFS/COFF readers, `auxdis.py` disassembler, build scripts, MAME/QEMU harnesses. Python: `aux605/.venv/bin/python`. Its `build/` is ignored (ROM/kernel-derived bytes). |
| `analysis/` | Symbol dumps, disassembly listings (Apple-derived, not in the repo). |
| `roms/`, `images/`, `extras/` | Jeff's ROM dumps, Shoebill HD images, System Enabler 065 download. |
| `work/` | Read-only working inputs: `aux31.unix` (3.1 `/unix` from `AUX_3_1_1GB.dsk` part 5), `aux31-605.hd` (that disk + Enabler 065 in its HFS System Folder; `cp -c` a clone per MAME run), `ff7439ee.bin` (605 ROM, unzipped). |

**Never `hmount` an original image.** hfsutils opens images read-write and rewrites the
MDB (it did this to `AUX_3.1_Update.iso` on 2026-10-28: volume last-modified date and
file mtime changed; file contents untouched). Mount a `dd` copy of the partition instead.

## How A/UX boots (relevant parts)
1. Mac OS runs **A/UX Startup** (SASH). It checks for FPU + PMMU via Gestalt; no machine
   allow-list found in its strings (still to confirm by disassembly).
2. SASH runs **`launch`**, which loads `/unix` (m68k COFF, magic 0x150) and passes a kernel
   info block; the kernel copies `machineID` from it in `scopy%` (pstart 0x54032).
3. `/unix` is **link-time configured**: `autoconfig` links `/etc/config.d/newunix` (fully
   linked core, has symbols, no relocs) with `/etc/boot.d/*` (ar archives of COFF objects).
   Apple's own AWS 95/3.1 upgrade ships as *cpio over / + `autoconfig -Iu -o /unix -S /etc/startup`*:
   that is our delivery template.

## The gate: `boardinit` (pstart 0x57ff2, 3.0.1 `/unix`)
`machineID` = **Gestalt − 2**. `boardinit` does `switch(machineID)` over 4..0x39 and
**panics "unsupported motherboard type"** otherwise. Quadra 605 = Gestalt 94 → **0x5C**;
LC 475 = 89 → 0x57; LC 575 = 92 → 0x5A. All out of range.

| A/UX id | Machine | boardinit case |
|---|---|---|
| 4–7 | II, IIx, IIcx, SE/30 | nothing special |
| 9, 16 | IIci, IIsi | RBV |
| 11 | IIfx | OSS/IOP |
| 18, 20, 24 | Q900, Q700, Q950 | 53C96 @0x50F0F000, DAFB monitor detect |
| 28, 33, 34, 50, 51, 57 | C650, Q800, Q650, C610, Q610, (Gestalt 59) | **djMEMC/IOSB** case at 0x5829e: 53C96 @0x50F10000, SWIM 0x5001E000, SCC 0x50F0C020, sound 0x50014000, `devices[5]=2` (→ `memcdjsize`), DAFB monitor detect |
| 42, 43, 46 | IIvi, IIvm, IIvx | present but never officially supported |

Other `machineID` consumers: `enable_caches`, `doboot`, `setup_rbv`, `setup_040` (no-op
list), `parityinit`, `orwellsize`, `restoreVideoInfoPtr`, `dopowerdown`, `egret_init`,
`egret_reset`. Device addresses mostly come from `boardinit`; `setupProductInfo` also copies
the ROM's ProductInfo (UnivInfoPtr @ $DD8) for ROM version ≥ $067C.

## 605 vs. its supported twin (Centris 650 / Quadra 800)
MAME: *"cost-reduced Wombat: djMEMC → MEMCjr, IOSB → PrimeTime (mostly compatible)"*.
Linux `config.c`: Q605 = Q800 on VIA, SCSI, SCC and floppy; differs in ADB, Ethernet, NuBus.

| Area | C650/Q800 (supported) | Q605 | A/UX work |
|---|---|---|---|
| Board ID | 0x1C / 0x21 | 0x5C | new `boardinit` case (or remap to 0x1C early + 605 overrides) |
| I/O ASIC | IOSB | PrimeTime (same map, real VIA core as VIA2) | likely none |
| SCSI | 53C96 + Turbo SCSI in IOSB | same | likely none |
| Memory ctl | djMEMC (`memcdjsize`) | MEMCjr (different regs) | new sizing routine, or trust ROM RAM table |
| Video | DAFB II in djMEMC, VRAM 0xF9000000, regs 0xF9800000 | DAFB II in MEMCjr, same addresses, **regs written 6 bits at a time via holding reg 0x5000E07C** | fix `DAFBReadSenseLines`/`_DAFBMonitorDetect`; mode/CLUT go through the ROM driver |
| ADB | VIA-based "ADB modem" (`via_fdb_*`) | **Cuda** on VIA1 PB3 TREQ / PB4 BYTEACK / PB5 TIP + SR | **new Cuda driver**, adapted from `egret_*` (Linux `via-cuda.c` covers both) |
| RTC / PRAM / power-off / reboot | VIA RTC chip, VIA2 power | Cuda | route through Cuda (Egret path already sends 0x0A power-down) |
| Ethernet | onboard SONIC | none (PDS card) | none expected |
| Expansion | PDS + NuBus | PDS only | none expected |
| Sound | IOSB ASC-like | PrimeTime ASC-like + DFAC II (via Cuda I²C) | optional |
| ROM | $067C | $067C? (MAME: `ff7439ee.bin`) | verify; A/UX has `Patch.0178` and `Patch.067C` Toolbox patch sets |

## Test beds
ROMs live in `roms/` (Jeff's dumps; never redistribute). Both verified 2026-10-28:

| File | Use | Check | ROM version / release (+8 / +$12) |
|---|---|---|---|
| `roms/macqd605.zip` (`ff7439ee.bin`) + `roms/cuda.zip` (Cuda 2.xx MCU set) | MAME 0.289 `macqd605` | `mame -rompath roms -verifyroms macqd605` → good; boots to the "?" floppy | $067C / $26F1 |
| `roms/quadra_800.BIN` | QEMU 11.0 `-M q800 -bios roms/quadra_800.BIN`; also MAME `macqd800` (`f1acad13.rom`, same SHA1) | boots to desktop pattern | $067C / $23F2 |

Same ROM version ($067C), so A/UX should pick `Patch.067C` on the 605, but the ROM
*release* differs ($26F1 vs $23F2). Any patch in that set that hard-codes ROM offsets may
miss on the 605: check how `Patch.067C` is keyed before trusting it.

Headless MAME run: `mame macqd605 -noreadconfig -rompath roms -cfg_directory … -nvram_directory …
-snapshot_directory … -video none -sound none -nothrottle -seconds_to_run N` (writes a final PNG).

### Prebuilt HD images (`images/*.zip`, Shoebill images)
Unzipped read-only to `extracted/hd/`. Boot only throwaway copies: a qcow2 overlay for
QEMU, an APFS clone (`cp -c`) for MAME.

| Image | RELEASE_ID | HFS (Mac OS) | Kernel | Result |
|---|---|---|---|---|
| `Apple_UNIX.iso` (321MB) | **A/UX 3.0** (Mar 9 1992), not 3.0.1 | System 7.0.x | no `memcdjsize`/DAFB detect: predates Centris/Q800 | not useful on q800/605 |
| `AUX_3_1_1GB.dsk` (1GB) | **A/UX 3.1** (Feb 25 1994), AWS 95 build | System 7.1 + Enabler 040, A/UX Startup in Startup Items | `boardinit` same 4..0x39 table as 3.0.1 | **QEMU q800: boots to A/UX Finder in ~22s** ("Welcome to The Apple Workgroup Server 95"), autologin. **MAME 605: Mac OS refuses**: "System 7.1 does not work on this model" (needs System Enabler 065) |

Harnesses: `aux605/tools/qemu-shots.py` (q800 + periodic `screendump`), `aux605/tools/mame-snap.lua`
(`-autoboot_script`, snapshot every 4s).

- **MAME** `macqd605` (working; emulates a full 68040): the 605 target.
- **QEMU** `q800` boots A/UX 3.0.1 upstream: the known-good baseline.
- **cat7/m68k-rom** QEMU fork: `lc475` machine with Cuda. Unvetted.

## MAME 605 bring-up log (2026-10-28, A/UX 3.1 image)
Setup: clone of `AUX_3_1_1GB.dsk` with **System Enabler 065 v1.2** added to the HFS System
Folder (`extras/System_Enabler_065_12-sea.bin` → `unar` → `aux605/tools/macbin.py` → `hcopy -m`
into a `dd` copy of the HFS partition → `dd conv=notrunc` back into the clone). MAME
`-ram 32M` (the default 4M is the onboard RAM only and too little for A/UX).
Script: `aux605/tools/mame-605-probe.lua`.

1. Without the enabler: Mac OS refuses ("System 7.1 does not work on this model").
2. With it: 7.1 boots, A/UX Startup runs "Loading…", launch → kernel `_start`. **No booter
   gate.** `boardinit` sees machineID 0x5C → panic path → `panic()` (in .text) is called from
   physical mode → runaway (grey screen).
3. Spoof 0x1C at `boardinit`: `memcdjsize` reads MEMCjr reg 0x50F0E02C = **0**, so bank 0 =
   [0x15b000, 0) and the page-table setup corrupts pstart data (`cputype` gets clobbered) →
   030 MMU path on an 040 → runaway. (CPU detection itself is fine: F-line trap → cputype 5.)
4. Spoof 0x1C + `devices[5]=0` (generic `banksize` probe): RAM sized correctly (32MB), 040
   MMU on, then `vadrspace` → via1init → via2init → egret_init (skipped, needs RBV) →
   iop_init → video_init → initMacEnvironment → ROM `StartSDeclMgr`. **The 605 ROM calls
   `_EgretDispatch`**, which A/UX routes to its own Egret driver (aEgretDispatch →
   cEgretDispatch → send_packet). Byte exchange with Cuda works; an unsolicited packet goes to
   get_urgent_response → `onesec` → `viaclrius` → **panic "viaclrius called from
   non-interrupt"** (onesec only skips viaclrius on RBV machines, `devices[1]`).

5. Same with `-ram 128M`: `banksize` sizes 0x8000000 correctly; same panic.

**Jeff's real 605:** full 68040, 4MB onboard + **128MB SIMM** (~132MB, beyond Apple's 36MB
spec; MEMCjr handles 128MB banks), **1MB VRAM** (upgraded; MAME emulates 1MB for all MEMC
machines). MAME has no 132M option; 128M is the closest test. `banksize` walks memory one 4KB page at a time
(pattern + alias-to-0 check), so non-power-of-two totals are fine, **but** a bus error past
the end of RAM jumps to `memerror%` and abandons `memsize` before the bank is recorded.
MAME mirrors RAM so it can't show this; on real MEMCjr hardware we don't know. A
safer 605 routine would take the RAM size from the ROM/booter rather than probing.

6. Stubbing `aEgretDispatch` (result 0, return): kernel reaches `main()`, all drivers
   attach (SCC, SWIM, SCSI 53C96 finds disk+CD, 128MB/32MB sized), init execs, but init
   loops: `open("/dev/syscon")` → **ENXIO**, relink to systty, write, `sync` (constant SCSI
   writes). Screen stays grey because launch's video driver call greyed the whole CLUT
   (VRAM still holds A/UX Startup's "Launching…" dialog); the Mac environment restores it.

### 2026-10-28 evening: kernel boots to the A/UX Mac environment on the 605 (MAME)
All via `aux605/tools/mame-605-probe.lua` in-RAM patches on the 3.1 kernel:
`BOARD=switch CUDA=build/cuda-aux31.lua PRODINFO=build/prodinfo-605-full.bin
PRODINFO_AT=5dd00 PRODINFO_PTR=10001d00`. Result: kernel console up, init runs, the A/UX
Toolbox (user-mode Mac environment) starts and shows **"This startup disk will not work on
this Macintosh model… (System 7.0.1 does not work on this model…)"**: the A/UX System file's
own model check. Everything below the Mac environment works.

The pieces (what the eventual patch must do), in boot order:
1. **boardinit**: map 0x5C to the Centris 650 case *only at the switch* (`d0` at
   `boardinit+0x434`); keep `machineID` = 0x5C for everyone else.
2. **devices[1] = 1** ("has Egret") after boardinit: turns on egret_init, Egret ADB
   (`fdb_init` → `egret_fdb_start`), Egret power-off/reboot, interrupt setup, DFAC. All
   devices[1] users: onesec, dopowerdown, doreboot, egret_init/shutdown, init_egret_onesec,
   setup_autovectors, via1init, fdb_init, setDFACByte.
3. **devices[5] = 0**: generic `banksize` RAM probe instead of `memcdjsize` (MAME's MEMCjr
   returns 0 for all regs except 0x7C; real MEMCjr may have a usable top-of-RAM register,
   unknown).
4. **Cuda transport** (`aux605/src/cuda.c`, built by `aux605/tools/build-cuda.sh`): linked at
   `cEgretDispatch`, overwriting it and the Egret byte-level helpers (`send_packet` …
   `get_urgent_response`, all internal); `jmp` stubs at `shift_reg_intr`, `egret_reset`,
   `abort_pending_transactions`. Reuses A/UX's `valid_packet`, byte-count tables, `resprec`,
   fdb/key completions. Signalling per Linux via-cuda.c (TIP/TACK active low, TACK toggles per
   byte, idle byte before each packet, open-ended replies stopped by the host when full).
   Verified: ROM PRAM/6805 reads, RTC (`unix=1793207278`, correct date), set time.
5. **Built-in video**: init's console (`disp_open`, major 7) needs `video_count ≥ 1`;
   `video_find` asks the Slot Manager for slot 0's display sResource. The 605 ROM's
   ProductInfo (`$408A82C0`) → VideoInfo (`$408A894E`) says **VRAMLogAddr32 = $51900000**
   (Mac OS on the 605 really has `ScreenBase = $51901000`: the 605 ROM's MMU maps VRAM
   there). A/UX's supervisor TTs map $40–$7FFFFFFF 1:1, so $519xxxxx is not VRAM and the ROM's
   slot-0 primary init leaves no display sResource (`smNoMoresRsrcs`). Fix that works: a
   full **0x48-byte** relocated ProductInfo copy whose VideoInfo copy says $F9000000
   (`aux605/tools/prodinfo-copy.py`), installed as `ProductInfoPtr` (→ `$DD8` via
   `setup_lowmem_globals`). Then slot 0 → `getDevBase = $F9001000`, `video_count = 1`.
   - A/UX's own `setupProductInfo` copies only **0x34** bytes (fields up to +0x30). The 605
     ROM also uses **+0x34 and +0x38** (e.g. `_WriteXPRam` → `ProductInfo+0x34` → routine
     table → `jsr`): a 0x34-byte copy crashes with a garbage PC. Relocatable fields: +00 04
     08 0C 28 2C 30 34 38; 0 means absent and must stay 0.
   - `UI_get_prodinfo` gives user Mac processes only 0x34 bytes too: watch for the same
     problem in the Toolbox.
   - The copy must be readable in physical mode too (`get_rbv_info` in boardinit read 0
     through 0x10001d00); harmless here but put the real copy somewhere identity-mapped or
     install it after `turnon_mmu`.
6. **.text physical address** while the MMU is off = `endpstart` rounded up to 4KB
   (0x5c000 for 3.1), not `endpstart`.

Takeaways: kernel-side port = boardinit switch remap + devices[] flags + Cuda transport +
ProductInfo/VideoInfo fix. Next gate is the Mac environment (System 7.0.1 model check).

### 2026-10-28 night: A/UX Finder on the 605 from a patched disk (MAME)
A clone of the 3.1 disk with two binary patches applied (`tools/binpatch.py`, no in-RAM
help, no debugger) boots on `macqd605` through StartMonitor ("Welcome to The Apple
Workgroup Server 95") and autologin to the A/UX Finder: `-ram 32M` at t≈104 s,
`-ram 128M` at t≈140 s (emulated).

**Toolbox model check.** The A/UX System 7.0.1 (`/mac/lib/SystemFiles/private/System`,
AppleSingle) shows DS alert 102 (text −20103, `DSAT` 0) from its `boot` 2 resource:
`btst #6,ROM85 / cmpi.b #$14,BoxFlag / ble ok / SysError(102)`, i.e. it refuses any BoxFlag
above the Quadra 950. A/UX gets newer machines past it in the Toolbox, not the System:
`GetLowFromKernel` in `/mac/lib/Patches/Patch.067C` (the Toolbox image startmac loads for
ROM version $067C; a COFF with full symbols) saves the kernel's BoxFlag in `realBoxFlag` and
rewrites BoxFlag to 0x10 (Quadra 700) for 0x18, 0x1D, 0x1E, 0x2E, 0x2F, 0x35 (C650, Q800,
Q650, C610, Q610, …); `InstallMyGestalts` then answers Gestalt `mach` = realBoxFlag + 6 and
`micn` from it. The 605's ProductKind is **0x58** (Gestalt 94). Fix
(`patches/toolbox-605.txt`, 8 bytes at `GetLowFromKernel+0x3a`): the redundant second load
of BoxFlag becomes `cmpi.b #$58,d0 / beq` to the "BoxFlag = 0x10" exit. All later BoxFlag
readers in the Toolbox (`doVariables`, `cSysBeep`, `do_new_boot`) run after it and see 0x10
as on a C650. The same 8 bytes are at the same symbol in 3.0.1's `Patch.067C`.

**ROM release $26F1 vs the Q800's $23F2.** Same layout, ~60 differing regions (605
hardware). Checked every place the Toolbox path binds to a fixed ROM address:
- `Patch.067C`: 15 absolute ROM jumps (`mGetResource`, `addromrsrc`, `unixchkload`,
  `GetFCBInfo_patch`): identical code in both ROMs. `doROMArray` takes its entry points
  from the ROM's ForeignOS table (ROM+$16), not fixed addresses.
- System `lpch` (compressed, `dcmp` 2; the $067C set is IDs with bit 4): 417 ROM binds, the
  $067C offset is the first 3-byte group of each entry. 414 point at identical code, two
  differ only in a `bsr` displacement inside the routine, one (ROM+$0887B2, `lpch` 24) is the
  same entry with a nil check dropped. The loader's release conditions key on the release's
  high byte ($15/$17 vs other): the 605 takes the Q800's branch.
- `PTCH` 1660: 168 relocated ROM references, all identical; its release-specific code is
  for high byte $15/$17 only. `SMLinkedPatchInit`'s `lpch` have no ROM binds.
- `ptch` 42 returns into ROM+$0870AA, which differs on the 605, but it is the VM patch:
  `boot` 2 skips it when HWCfgFlags bit 9 (hwCbAUX) is set, as the Toolbox sets it.

**ProductInfo seen by user processes.** `InitUniversalPtr` gets 0x34 bytes through the UI
device ioctl (`UI_get_prodinfo`: `copyout(*$DD8, buf, 0x34)`) and rebases the offsets
against the kernel's `$DD8`. The ROM readers of +0x34/+0x38 are the same 7 sites in the
Q800 and 605 ROMs (plus 605 start-up code the Toolbox never runs), so the 0x34 limit is no
worse than on a supported Q800. A MAME breakpoint on every ROM instruction that reads
VideoInfo or +0x34/+0x38 hit 75 times from power-on to the Finder, all in supervisor mode
(the kernel; 66 at the +0x34 PRAM/RTC path ROM+$0B1A4), none from the Toolbox. Caveat: with
our RAM copy the Toolbox's rebased VideoInfo pointer lands in its own address space
(startmac text), so a Toolbox path that does read VideoInfo would get garbage; fixing that
means `UI_get_prodinfo` (in `boot.d/toolbox`) handing out a view whose VideoInfo points at
the ROM's. Not seen so far.

**Kernel: real patch instead of in-RAM patches.** `tools/build-kernel605.sh KERNEL NAME`
links `src/cuda.c` + `src/boot605.S` over `cEgretDispatch` (1732 of the 2028 dead bytes up to
`shift_reg_intr`; nothing outside that range calls into it except via `cEgretDispatch`),
and `tools/kernel-patch.py` finds the call sites and writes the binpatch spec:
- `boardinit+0x14` (`move.w machineID,d0; ext.l d0; bra.w switch`) → `jmp b605_switch`
  (physical): 0x5C takes the C650 case at the switch only (boardinit also reads machineID at
  +0x1CA/+0x1D6/+0x1FA/+0x2AC, for the Q900/Q950 paths).
- `_start`'s `jsr boardinit` → `b605_board` (physical): on 0x5C sets devices[1]=1,
  devices[5]=0 and builds the ProductInfo copy from the ROM's own record (at boot
  `*(kstart+$DD8)` is the ROM's $408A82C0, so `setupProductInfo` copies nothing and A/UX
  normally uses the ROM record in place). No ROM bytes are in the repo or the patch.
- `vadrspace`'s `jsr setup_lowmem_globals` (right after `turnon_mmu`) → `b605_lowmem`:
  ProductInfoPtr = the copy, which setup_lowmem_globals hands to the ROM as `$DD8`. The copy
  is written with the MMU off at its physical address and only read once it is on, so
  physical-mode readers (get_rbv_info) now see the ROM's record: `rbv_base_addr` becomes
  $51900000 (was 0), used only when `rbv_monitor` is set (IIci/IIsi), so harmless.
- The Cuda `jmp` stubs as before.
The hooks only act on machineID 0x5C. Why not a `boot.d` module: everything here runs before
any module init, and newunix is fully linked (no relocations, no undefined symbols), so it
cannot call into module code whose address depends on the configuration. Instead the same
spec patches `/unix` and `/etc/config.d/newunix`: autoconfig only rewrites configuration
data (pstart $5B070…, .data), and a forced relink in MAME (`autoconfig` without `-a`)
produced a `/unix` with byte-identical pstart, .text and .data (only the COFF timestamp
changed). `sysinitrc` runs `autoconfig -a` every boot; `-a` relinks only when the modules
don't match the hardware.

**3.0.1.** `build-kernel605.sh` links unchanged against 3.0.1's `/unix`: `cEgretDispatch` and
the whole Egret driver are at the same addresses; the code differs only in operand
addresses and `egret_init`'s `egret_delay_cnt` tweak (3.0.1: Q900 only; we never use that
counter, `egret_delay_us` is calibrated from `via_access_per_ms`). All seven sites verify on
the 3.0.1 CD's installable root (partition 6) and on the CD's own boot root (partition 4,
a smaller `/unix`), and the Toolbox patch verifies on both. Not booted yet: no installed
3.0.1 disk.

### 2026-10-28 late: A/UX 3.1 is the target; reproducible 605 disk
Jeff: "Ultimately I want 3.1", so the 3.0.1 install is dropped; the base is the Shoebill
`AUX_3_1_1GB.dsk` (A/UX 3.1, System 7.1). `tools/make-605-disk.sh` builds the 605 disk from it
and the System Enabler 065 download (the old `work/aux31-605.hd` had also been booted once:
three UFS blocks and the HFS Clipboard/Preferences differ from the pristine image). The
built disk reaches the A/UX Finder on MAME `macqd605 -ram 128M` without a debugger, and the
same disk still boots QEMU q800 to the Finder: the hooks leave other machines alone.

**RAM sizing on real hardware (unverified).** With devices[5] = 0 and no RBV, `memsize` calls
`banksize(0, kernel end, &rambanks)`. That probes 4KB pages upward from the kernel end with
no upper limit (5AA5/A55A pattern, lowmem $0 and power-of-two alias checks) until a check
fails. During it the bus-error vector points at `memerror%` in `_start`, which skips the rest of
`memsize` and goes on to `mmusetup`, so a bus error at the end of RAM leaves the bank
unrecorded. MAME mirrors RAM (the alias check ends the probe); whether real MEMCjr
terminates accesses past the last SIMM or bus-errors is unknown.

First real-hardware boot (Jeff's 605, BlueSCSI, 132MB): Mac OS 7.1 and A/UX Startup run
("Checking…", "Loading…", "Launching…"), the screen goes dark as it does in MAME at launch,
then disk activity stops: the kernel dies before mounting root, which fits this probe.
So `src/boot605.S` now has `b605_banksize`, called from memsize in place of banksize (the
hook only acts on 0x5C): the same algorithm and results, plus a bus error catch around each
probe (end of RAM, as `pdsprobe` treats absent PDS cards) and a limit of Mac OS's BufPtr
rounded up to 1MB. launch leaves BufPtr at `kstart+$10C`; `kstart+$108` (MemTop) is the
kernel's end there, and launch's kernel-info block carries no RAM size. BufPtr is the RAM
size less 0x20358 / 0x3A358 / 0x4A358 at 32 / 128 / 192MB in MAME. Checked in MAME: same banks
as banksize (32MB: `0 15b000 2000000 1`), 128MB and 192MB to the Finder, a faked bus error
at 24MB gives 24MB and boots on; QEMU q800 unaffected. (memsize's own bzero of the low bank
$4000-$54000 clears the bus error vector at $50008 afterwards, in the original too.)

### 2026-10-28 late: still hangs on real hardware; checkpoint kernel
v2 (with `b605_banksize`) behaves exactly like v1 on Jeff's 605: kernel launched, screen
dark, disk quiet. So RAM sizing was not it, or not only it. In MAME: the kernel touches no
unmapped address (MAME logs unmapped accesses to `error.log` under `-log`; only ROM code
appears), but MAME's PrimeTime is its IOSB model and accepts everything the C650 path
touches, so that proves little. 192MB boots to the Finder in MAME (no software limit
above 128MB). The DAFB writes in the C650 case are only to the sense register (+$1C, values
3/5/6/7), which MEMCjr's 6-bit path passes unchanged. In the C650 case `cpuspeed` is set
only for C650/Q800-family IDs, so on the 605 it stays at the default 0x10 (16MHz; the 605 is
25MHz): it scales SCSI timeout loops (`scsisched`, `scsitask`, `choosetask`), to be fixed.

**Checkpoint kernel** (`CKPT=1 tools/make-605-disk.sh …`, `-DCKPT_BUILD` in
`src/boot605.S`): launch leaves Mac OS's KeyMap at `kstart+$174`, so the kernel can see a
digit key held through "Launching…" (verified in MAME). Holding key N makes the kernel
restart through the ROM (`move.w #$2700,sr; jmp $4080000A`, as A/UX's `doboot`) when it
reaches checkpoint N; a startup chime means "got this far". Checkpoints: 1 kernel entry
(`b605_board`, before boardinit), 2 after boardinit, 3 RAM sized (`b605_banksize` end), 4 MMU
on (`b605_lowmem`), 5 before `egret_init` (VIAs done), 6 before `video_init` (Cuda up), 7
before `fdb_init` (video up), 8 before `startup()` from main, 9 before `iinit` (drivers incl.
SCSI started, before root mount), 0 (=10) before `nvram_init` (root mounted). 5-7 are
`init_first` table entries, 9/0 `initfunc` entries, 8 main's `jsr startup`: /unix only,
since autoconfig writes those tables. To make room, the ProductInfo buffer moved into
`egret_reset`'s dead body (`.text2`, also used by the trampolines). MAME
(`tools/mame-ckpt-test.lua`): keys 1, 5 and 0 restart as designed; no key boots to the
Finder. Image sent to Jeff as `~/Downloads/aux31-605-ckpt.hd`; results pending.

### 2026-10-28 late night: the hang is in boardinit; v3 and a finer checkpoint image
Jeff's 605 with `aux31-605-ckpt.hd`: key 1 chimes, key 2 does not. So the kernel gets in,
and either `boardinit` (C650 case for 0x5C) never returns, or it returns and the restart
from checkpoint 2 fails to chime.

**What boardinit touches.** For 0x5C: `setupProductInfo` (reads the ROM version and the
ROM's ProductInfo), stores to kernel data, `_DAFBMonitorDetect`, `get_rbv_info` (ROM reads).
The only hardware access is DAFB, in `_DAFBMonitorDetect` → `DAFBReadSenseLines`
($F9800000): `DAFBResetDelay` (4 × `tst.l $2C(a0)`), read $1C, write 7 to $1C,
`DAFBResetDelay` again; `ReadExtendedSense` (writes 3, 5, 6 to $1C) if the lines read 7.
Nothing else in the kernel touches DAFB. The kernel runs with the MMU and caches off
(CACR 0) and VBR $50000, and the bus error vector does not point at `memerror%` until
just before memsize, so a bus error here runs off into nothing.

**DAFB on MEMCjr.** Both the 605 ROM (ROM+$F76D4, $F81EE) and the Q800 ROM sense the same
way (long read of $1C, `move.l #7,$1C`), but pause with VIA reads (`tst.b ([$1D4])` × 3),
never with DAFB $2C reads (the ROM reads $2C only for the DAFB version, conditionally).
MEMCjr passes 12-bit registers 6 bits at a time: a read leaves the upper six bits in the
holding register (MEMCjr+$7C, $50F0E07C) and the next write ORs them in. The 605 ROM loads
it explicitly before 12-bit writes (`ror.l #6,d0; move.l d0,$7C(a2); rol.l #6,d0; move.l
d0,$30(a2)`), for MEMCjr's own registers ($30, $34) too; MAME models it for DAFB only. A/UX's
sequence ends on $2C reads, so `boardinit` returns with $2C's upper bits (DAFB version 3 →
$18) in the holding register. Two readings of key 2:
- (A) a DAFB access hangs or bus-errors on real MEMCjr ($2C is the odd one out);
- (B) boardinit returns, but the restart (a `jmp` to the ROM, not a hardware reset)
  inherits the holding register and the ROM's own MEMCjr/DAFB set-up writes go wrong.
Under (B) the real hang may be later, possibly from the same stale register.

**v3** (`~/Downloads/aux31-605-v3.hd`, Jeff to try first): new hook `b605_sense` at
`_DAFBMonitorDetect`'s `jsr DAFBReadSenseLines`; on 0x5C it returns sense 6 (13" RGB)
without touching DAFB, so `obv_monitor` = 1 as in MAME (slot 0 enabled; the ROM's driver
does its own sensing); `monitorID` is only read for the Q950. Other machines go to
`DAFBReadSenseLines`. Also `cpuspeed` = 25 on 0x5C (in `b605_board`). MAME `-ram 128M`:
Finder at t≈168 s. QEMU q800: Finder at 90 s.

**Checkpoint image 2** (`~/Downloads/aux31-605-ckpt2.hd`, `CKPT=1`): the checkpoint code
now lives in `.text3`, linked over `orwellsize` (622 bytes in pstart, identity-mapped so it
runs the same with the MMU off or on; only Orwell machines call it), and `CKPT n` is
`move.w #n,-(sp); jsr ckpt` (10 bytes, `rtd #2`). 20 keys. This image keeps A/UX's own DAFB
sense code (`b605_sense` is an instrumented copy of `DAFBReadSenseLines`), and its restart
clears the holding register on 0x5C first, except key P, which restarts as the first image
did.

| Key | Checkpoint | Key | Checkpoint |
|---|---|---|---|
| 1 | kernel entry (before boardinit) | Q | before `egret_init` (VIAs done) |
| 2 | `setupProductInfo` done (at the switch) | W | before `video_init` (Cuda up) |
| 3 | before the first DAFB access | E | before `fdb_init` (video up) |
| 4 | after the 4 DAFB $2C reads | R | before `startup()` |
| 5 | after the $1C read | T | before `iinit` (drivers started) |
| 6 | after the $1C write | Y | before `nvram_init` (root mounted) |
| 7 | sense read done | U | sense read 7: before `ReadExtendedSense` |
| 8 | boardinit returned | I, O | unused |
| 9 | RAM sized | P | boardinit returned, restart without clearing the holding register |
| 0 | MMU on | | |

MAME (`tools/mame-ckpt-test.lua`, which now logs each jump to the ROM restart with d0 = the
checkpoint): every key restarts at its own checkpoint and the machine boots again; U never
fires (MAME's monitor does not read 7); no key boots to the Finder.

Reading Jeff's results: 8 chimes → boardinit completes and the old key 2 was (B); P should
then stay silent, and the later keys find the real hang. 8 silent → 3–7 find the access
that hangs (A).

### 2026-10-28 night: A/UX 3.1 boots on Jeff's real 605
**The 33MHz ID.** Jeff's 605 runs at 33MHz. The 605 ROM picks its ProductInfo by the CPU ID
register ($5FFFFFFC = $A55Axxxx), and in the MEMCjr family the low bits of that ID give the
clock. Kinds and Gestalt below are from the ROM's records (Gestalt = kind + 6, A/UX
machineID = Gestalt − 2):

| CPU ID | Kind | Gestalt | machineID | Machine |
|---|---|---|---|---|
| $2221 | 0x53 | 89 | 0x57 | LC/Performa 475 (MAME `maclc475`) |
| $2222 | 0x54 | 90 | 0x58 | (475 family, 33MHz) |
| $222E | 0x56 | 92 | 0x5A | LC/Performa 575, 33MHz (MAME `maclc575`) |
| $2225 | 0x58 | 94 | **0x5C** | Quadra 605, 25MHz (MAME `macqd605`) |
| $2226 | 0x59 | 95 | **0x5D** | Quadra 605, 33MHz (Linux `MAC_MODEL_Q605_ACC`) |

Every hook acted on 0x5C only, so on Jeff's 0x5D board `boardinit` took A/UX's "unsupported
motherboard type" panic in physical mode. That explains checkpoint 1 chiming but not 2, and v1–v3
failing identically. Fix (v4): `is605` (machineID & ~1 == 0x5C) in every hook; the Toolbox patch
now tests BoxFlag 0x58 and 0x59 (20 bytes: the two tests plus the following range check
redone with word operations, ending on the original `bhi`; also verifies on 3.0.1's
Patch.067C); `cpuspeed` = 25 or 33 by the ID's low bit (it only sizes the SCSI polling
timeouts: cpuspeed×50/16, ×100/16). MAME can be made a 33MHz 605 with `CPUID=2226` in
`tools/mame-snap.lua` / `tools/mame-ckpt-test.lua` (a read tap on $5FFFFFFC).

**v4 on hardware:** checkpoint 8 chimes at once; 9 and later blank the screen, then chime
after ~10 s and a long RAM test (the ROM restart after the kernel has used RAM). With no key:
console panic `trap type 27`, PC in `c94_intr` (53C96 interrupt, SR $2200), "unexpected kernel
trap", after root was mounted. Vector 27 = level 3 autovector. `setup_autovectors` (called
from `vadrspace`) leaves vectors 27 and 29 (levels 3, 5) on `faulthdlr` and 30 (level 6) on
`pw0%` → `powerintr` (SIGPWR to init) for machineIDs above 0x10 except the IIfx; for the
Quadra 700 and older it points all three at `nointr` (`rte`). The 605 interrupts at levels 1, 2
and 4 only (MAME's PrimeTime raises nothing else), and a stuck level 3 would have fired as
soon as main lowered the IPL, so this was a one-off: most likely the IPL lines reading 3
for a moment between levels 1 and 2, which an overclocked 040 can sample. Not confirmed.

**v5** (`~/Downloads/aux31-605-v5.hd`): new hook `b605_vectors` at `vadrspace`'s `jsr
setup_autovectors`: on the 605, `autovec`+8/+16/+20 (levels 3, 5, 6) = `nointr`, then
`setup_autovectors` copies the table to 0 as usual. **Jeff's 605 boots A/UX 3.1 to the
Finder**: floppy access, root, StartMonitor, Finder. Open: a strip of patterned pixels
at the right edge of the screen, beyond the menu bar's rounded corner (so past QuickDraw's
640 columns). It was already there on the kernel console (the panic screen), where the console
text's first characters were also cut off at the left.

### 2026-10-28 night: the shifted picture under A/UX
Jeff: Mac OS's picture is right. Under A/UX the whole picture sits shifted left: the
pointer goes fully off the left edge, and a strip of junk (the next bytes of each row)
shows at the right edge. The same at 640×480@60 and 800×600@56, Dell LCD over VGA, Auto
Adjust no help. So the line's pixels start late relative to the active window; nothing is
wrong with the framebuffer address.

A/UX's kernel runs the ROM's slot initialisation again (`video_init` → `initMacEnvironment`),
so the DAFB primary init (ROM+$F696E) runs a second time, on hardware Mac OS has already
set up. MAME (`macqd605`, monitor config "640x480 VGA" = ext sense 0x57, CPU ID $2226, a write
tap on $F98xxxxx/$50F0E07C) logs that run: after the normal timing writes it also takes
the branch at ROM+$F7E66 (gated on `-$4f(a6)`, set from a RAMDAC register read at
ROM+$F7194), which does read-modify-write adds to $168 and to HAL/HFP ($140/$144). Mac OS's
own mode sets in the same log don't take that branch. On MEMCjr the ROM's read helper
(ROM+$F845E) gets the upper six bits from the holding register; MAME's `memcjr_r($7C)`
returns `m_dafb_holding >> 6` (always 0, since reads store the bits unshifted), so in MAME
the adds produce junk (HAL = HFP = 8) that its renderer ignores (width 0), and the shift
can't show there. On hardware they move HAL/HFP by a constant.

The primary init also reads the CPU ID byte at ProductInfo+$45 (bit 1 = 33MHz, bit 0 =
25MHz) to choose MEMCjr pipeline settings (ROM+$F7052, $F7108); our ProductInfo copy has it.

**v6** (`~/Downloads/aux31-605-v6.hd`) put Mac OS's HAL/HFP/$168 back after the kernel's
primary init. Jeff: no change. Fewer colours make the shift larger, 256 is closest, and
Thousands draws giant overlapping UI. DAFB's horizontal registers count in units of a
depth-dependent divided clock (MAME `recalc_mode`: width = (HFP − HAL) × divider), so a constant
HAL/HFP error shifts by more pixels at lower depths. The register log at the A/UX Finder
(t≈126) shows the raw mode-table values HAL $88 / HFP $308 / $168 $2A. Mac OS's mode set
(t≈74) runs a RAMDAC step and then the MEMCjr pipeline correction (→ $83 / $303 / $20). A/UX's
mode sets skip both.

**Root cause.** The DAFB driver (DRVR `.Display_Video_Apple_DAFB`, ROM $F9EE8: Open $F9F88,
Control $FA2C6) gates that step on its global `$22(a3)` (`tst.b $22(a3); beq` at ROM+$FB53E).
Open sets it from bit 1 of byte 6 of slot 0's PRAM record (ROM+$FA1BA). The primary init
writes that bit when its RAMDAC probe finds this DAC (ROM+$F78C6). MAME breakpoints in both
RAM copies of the driver (A/UX: ROM + $21B284, Mac OS: ROM − $EB9D8) show that under A/UX Open
takes the error exit after `_SlotManager` sReadPRAMRec ($11). The PRAM bytes arrive (Cuda
log: `GET_6805_ADDR $0146` → `004d 83e4e4081e00`), but the 605 ROM's XPRAM routine (ROM+$B37EC:
builds a type-1 cmd-2/8 request, `_EgretDispatch`, returns d0) passes on the trap's d0, and A/UX's
`aEgretDispatch` (`move.l a0,-(sp); jsr cEgretDispatch; addq #4,sp; rts`) returns
cEgretDispatch's C result, **1 = done**, where Mac OS returns pbResult (0 = noErr). So every
`_ReadXPRam`/`_WriteXPRam` made by ROM code inside the kernel reports failure. The kernel's own
callers of `ReadXPRam`/`WriteXPRam` (nvram, init_time, UI_pram, scc_open, check_video_depth)
ignore d0. (The `pbResult = $4080` I logged at cuda_dispatch's return was a bad debugger
expression: cuda_dispatch writes pbResult only on failure, and valid_packet clears it.)

**v7** (`~/Downloads/aux31-605-v7.hd`): v6's save/restore removed. New hook `b605_egret` at
`aEgretDispatch+2` (`jsr cEgretDispatch`): on the 605 it calls cEgretDispatch and returns
d0 = pbResult (sign-extended, condition codes set); elsewhere it jumps to cEgretDispatch as
before. MAME (VGA, CPU ID $2226): Open now gets past sReadPRAMRec, A/UX's mode sets run the
RAMDAC step and the correction (final HAL/HFP $83/$303, as Mac OS), and the Finder comes up
in the depth saved in PRAM (1-bit in a fresh MAME PRAM; v6 came up in colour because the
PRAM read failed). **Jeff's 605: picture right at every colour depth.**

**RAM size on hardware.** Jeff's About This Macintosh under A/UX v7: Built-in Memory
135,168K (132MB, so `b605_banksize` sizes it right), Total Memory 16,384K. The second is the
Mac environment's own size, not physical RAM: `bt_3` in `/shlib/libmac1_s` takes it from
`startmac -m`, `$TBMEMORY` or the "memory size" preference (all via `__tb_ScaleArg`: a number
with an optional K/M suffix), else `__tb_GetVMSize` (the System file's `'vm  '` resource 0,
long at +4), else physical RAM capped at 16MB (`cmpi.l #$1000000`); minimum 3MB. Stock A/UX
behaviour on any machine with more than 16MB.

### 2026-10-28 night: scope is the 605; Egret guard; A/UX's own DAFB sense (v8)
**Scope.** Jeff: the patch can be for a specific set of machines and avoided on others, so
the original Egret code no longer has to survive byte for byte (that would need ~2KB of new
space; the dead tails behind our stubs give ~390 bytes). Who reaches the replaced code: every
caller of cEgretDispatch, egret_reset, abort_pending_transactions and shift_reg_intr is behind
`devices[1]` (egret_init, egret_shutdown, init_egret_onesec, fdb_init → egret_fdb_start,
setDFACByte), except `aEgretDispatch`, the kernel's handler for the ROM's `_EgretDispatch`
(pointer in a .data table at $1100AED8). `boardinit` sets `devices[1]` for 0x10 IIsi, 0x12
Quadra 900, 0x18 Quadra 950 (the AWS 95 itself), 0x2a IIvi, 0x2b Performa 600 and 0x2e IIvx
(switch table at boardinit+0x44c: entry = machineID − 4). Every other supported machine runs
A/UX's original paths with the patch in (hence QEMU q800 as the regression test).

**Guard** (`src/cuda.c`, `ON605`): on anything but 0x5c/0x5d, `cuda_reset` returns at once,
`cuda_dispatch` fails with pbResult −1 (the existing timeout path), and `receive_unsolicited`
does nothing, so `cuda_intr` only reads the shift register (acknowledging the interrupt) and
`cuda_abort` does nothing. `devices[1]` stays set: clearing it would send `fdb_init` to the VIA
ADB code, which drives the same PB4/PB5 lines a third way. On an Egret Mac a 605 kernel would
run without clock, PRAM or soft power (and without ADB on the IIsi/IIvi/IIvx; the Q900/950 use
the IOP), but would never touch the Egret's handshake. Untested: no Egret machine here.
Cost 64 bytes; to make room the MMU-on hooks (`b605_lowmem`, `b605_vectors`, `b605_egret`)
moved into `.text.boot605.extra` next to `pi_buf` (egret_reset's body). Free now: .text 102
(checkpoint build 46), .text2 32 (20).

**DAFB sense.** `b605_sense` is gone from the release build: `_DAFBMonitorDetect` calls
A/UX's `DAFBReadSenseLines` as on a Centris 650 (the checkpoint build still has its
instrumented copy). The checkpoint image run on Jeff's 605 with the 33MHz fix (v4's
checkpoint variant) went through this code to checkpoint 8 without hanging. It leaves DAFB
$2C's upper bits in MEMCjr's holding register; MAME clears the register on the next DAFB
write, so only that first write could be affected, and the ROM's mode code loads the
register itself before 12-bit writes. **v8** (`~/Downloads/aux31-605-v8.hd`): guard + A/UX's
own sense; not run in an emulator. **Works on Jeff's 605** (Dell LCD over VGA; Jeff,
2026-10-29), and v9 (same kernel) boots in MAME.

**Clock.** Jeff's 605 on v8: `date` says Sep 27 19:52:03 PST **1926**. How A/UX sets its time:
`init_time` (from `startup`) reads XPRAM $0C (`NuMc`) and $EC (location: `minswest`, DST),
then the ROM's `_ReadDateTime`, and prints `unix=…; mac=…; minswest=…; dst=…` on the console.
If the signature is missing it falls back to the root superblock's time at mount ("The
Macintosh system clock was invalid"; 2018-03-10 on this image). MAME, v8 (`TIMELOG=1` in
`tools/mame-605-probe.lua`): `_ReadDateTime` makes no Cuda request at all (it returns the
`Time` lowmem global, i.e. Mac OS's clock as launch left it), `mac_basetime` = $E7083027,
correct. At Toolbox start (t≈90) A/UX writes the clock back through `_EgretDispatch`: pseudo
$09 SET_TIME with local time per A/UX's TZ (PST8PDT; 8 hours behind MAME's clock, which
XPRAM said was GMT), then XPRAM $EC (location). So the boot time comes from the 605's own
clock, and our transport is only involved in that write-back. **Resolved: not the port.**
Mac OS 8 on the same machine shows the same 1926 date (battery new, PRAM keeps), and its
Date & Time panel only offers years 1920–2019 (two-digit window), so 2026 cannot be entered
there as is ("Show century" does not change that, Jeff). `stime()` from A/UX as root works
(Jeff): it also writes the Mac clock (stime → setthetime → SetMacClock). The Mac clock runs to
Feb 2040, A/UX's time_t to Jan 2038.

**`date` patch** (`patches/date-y2k.txt`, applied by `make-605-disk.sh`). A/UX 3.1's
`/bin/date` (stripped; same file as the AWS 95 upgrade's) takes `mmddhhmm[yy]`, and
`gtime` adds 1900 to `yy` and counts years from 1970, so `date 1029143026` sets 29 Oct 1970;
with no year it keeps the current one, which works. The patch rewrites gtime's year code over
its old year and day-count code (0x814–0x8f1, plus a `bra.w` at the old start 0x7c0, both up
to `gpair` at 0x90e): `mmddhhmm[[cc]yy]`, `yy` 70–99 → 19yy and 00–69 → 20yy, years outside
1970–2037 and trailing characters other than `p` refused. It also fixes the digit formatter
(0x970), whose two-digit case printed `%y`/`%D` as `<6` for tm_year 126 (one byte at 0x998).
Tested by running gtime and the formatter from the real binary under unicorn (68040),
original vs patched: 1,500 random dates 1970–2037 in both forms match `calendar.timegm`,
19yy inputs match the original, the edge cases are refused. Jeff ran it on v9 in MAME
(interactive, 25MHz 605): works. 3.0.1's `date` is a different
build (addresses shifted) and would need its own spec. `/bin/touch` has the same
`mmddhhmm[yy]` gtime (year code at 0x25a), not patched.

**Level 3 in the 605 ROM** (MAME, bare ROM, 8MB, autovectors read after boot; VBR = 0). Levels
5 and 6 → $40809B00, a bare `rte`. Level 3 → $4080A1B0, the common dispatcher with routine
$40809FC0 = `moveq #9,d0; jmp $40806EEC`, which runs the slot interrupt queue for slot 9
(`lea ([SlotQDT $D04],d0.w*4,$40)`): an expansion card's interrupt, no built-in device.
With no handler queued it returns $33 and the interrupt is dropped. So the 605 has no on-board
level 3, 5 or 6 source, and `b605_vectors` pointing them at `nointr` does what Mac OS does with
no card queued. Whether the one stray level 3 (v4, in `c94_intr` at IPL 2) recurs is
unknown, since `nointr` hides it; Jeff has nothing in the PDS slot, so it is taken as a glitch
and left alone (Jeff, 2026-10-29). A persistent OR of levels 1 and 2 is ruled out: with
`nointr` it would livelock as soon as VIA1 and the SCSI interrupt overlapped, and v5 onward
runs normally.

### 2026-10-29: the LC/Performa 475, in theory (untested on hardware)
**Why it should work.** The LC 475 and Performa 475/476 use the 605's ROM. Its MEMCjr
ProductInfo table (ROM+$A8038, $48 per record) has the 475 at kind 0x53 (CPU ID $2221,
25MHz) and 0x54 ($2222, 33MHz), next to the 605's 0x58 and 0x59. With the self-relative
pointers resolved, the 475 records point at the same decoder, RAM, video and routine tables
as the 605's and differ only at +$12 (ProductKind) and +$44 (CPU ID). Linux gives the
Performa 475 (Gestalt 89, 90) the 605's Cuda, VIA, SCSI and floppy types; its SCC type
differs (`MAC_SCC_II`, not `MAC_SCC_QUADRA`), but Linux uses that only to single out PSC
machines, and takes the SCC address from the booter. So the 475 gets the 605's treatment.
Every other kernel `machineID` test compares with IDs up to 0x39, so 0x57/0x58 take the
same paths as 0x5c/0x5d.

**Changes.**
- `ismemcjr` in `boot605.S` (was `is605`): machineID 0x57, 0x58, 0x5c or 0x5d. It now
  returns d0 = 1/0 with the condition codes set, and `cuda.c` calls it instead of its own
  `ON605`, so the test is in one place (the checkpoint restart keeps an inline copy,
  `IFMEMCJR`, as it runs in pstart). .text 1924 bytes, 2 less than before (checkpoint build
  1980 of 2028).
- `cpuspeed`: machineID's low bit means 33MHz on the 605 but 25MHz on the 475, so it now
  comes from bit 1 of the CPU ID's low byte (ProductInfo+$45), as the ROM's video init
  reads it; true at 33MHz in all four records.
- Toolbox (`toolbox-605.txt`): four BoxFlags don't fit the old 20 bytes. The site now runs
  to the jump table (36 bytes): the old range check, its `bhi`, the table dispatch and the
  `swbeg` header (`4afc 001e`), dead behind the `jmp`. Two unsigned range tests against
  d1 = 1 (0x53-0x54, 0x58-0x59), then the old range check in word operations and the
  dispatch moved up 4 bytes. d1 is free: the only caller, `doVariables`, calls
  `InitUniversalPtr` next and sets d1 before using it. Run under unicorn (68040) for all 256
  BoxFlags, original vs patched, on 3.1's and 3.0.1's `Patch.067C`: only 0x53, 0x54, 0x58,
  0x59 change (to 0x10), `realBoxFlag` unchanged. The spec verifies on all three copies.

**MAME.** `maclc475` has a 68LC040, so the test is `macqd605` with the CPU ID tap
(`CPUID=2221` / `2222` in `tools/mame-snap.lua`), `-ram 128M`, a `make-disk.sh --memcjr
--date` disk: Mac OS 7.1 with Enabler 065 accepts the 475, and A/UX reaches the Finder (t≈132
s at $2221), as do $2225, $2226 and QEMU q800. Read back at t=150: machineID 0x57 / 0x58,
cpuspeed 25 / 33, devices[1] = 1 (0x5c / 0x5d, 25 / 33 for the 605). No real 475 has run it.

### 2026-10-29: the LC III and LC III+ (Sonora), in MAME
Jeff's LC III: 25MHz board overclocked to 33MHz, 68882 fitted. Target: the LC III and
LC III+ at either clock, and their Performa twins (patch `patches/sonora/`, `--sonora`;
mutually exclusive with MEMCjr, free to break other Macs).

**Identity.** Gestalt 27 = LC III / Performa 450 (machineID 0x19), Gestalt 62 = LC III+ /
Performa 460/466/467 (0x3C; Linux `MAC_MODEL_P460`). The ROM ($067C, `ecbbc41c`) picks by
the CPU ID register (MAME: $A55A0001 / $A55A0003). (Assumed here that an overclocked LC III
stays 27; wrong, see below: Jeff's reports 62.) `boardinit`'s switch table (decoded): 0x19
falls on the panic case, 0x3C is past the table's end; both panic "unsupported motherboard
type" (confirmed in MAME). System
Enabler 003 v1.1 is needed for Mac OS 7.1; v1.0 lacks the LC III+'s ID. The LC 520, 550,
Color Classic II and Macintosh TV are Sonora/Ardbeg with Cuda instead of Egret: not covered.

**Hardware vs A/UX.** Linux `config.c` gives the LC III the IIvx's ADB (Egret), VIA (RBV
style), SCSI (`MAC_SCSI_LC`), SCC and floppy types; only expansion differs (PDS vs NuBus).
A/UX has an unsupported IIvx/IIvi/Performa 600 case (machineID 0x2a/0x2b/0x2e): `devices[1]`
= 1 (Egret), `devices[0]` = 3, `via2_addr` $50026000, `rbv_exists`, `obv_monitor` = 1 (video
with its own VRAM, not RBV's), cpuspeed 32. MAME's Sonora (`sonora.cpp`, `maclc3.cpp`): VIA1,
ASC, SWIM 2, pseudo-VIA and the SCC/SCSI decoded with A20-A23 ignored, so the Mac II
addresses A/UX uses ($500xxxxx) reach the same devices as the ROM's $50F0xxxx; VRAM at
$60000000; RAM one contiguous bank from 0; interrupts at levels 1 (VIA1), 2 (pseudo-VIA:
SCSI, ASC, VBL, PDS) and 4 (SCC).

Every other kernel `machineID` reader compares with single machines or with "above the
IIci/IIsi" (`doboot`, `setup_autovectors`, `enable_caches`), so 0x19 and 0x3C take the
IIvx's paths everywhere; switch-style readers (`setup_rbv`, `setup_040`, `parityinit`,
`dopowerdown`, `doPatches`) are equality tests too. Remapping only boardinit's switch value
to 0x2e (in RAM) took MAME's LC III through the whole kernel (SCSI disk and CD, SWIM, SCC,
Egret clock, slot 0 video) to the Toolbox's System 7.0.1 model check, the 605's last gate.

Checked and not needed:
- Pseudo-VIA IFR clear: Linux clears with bit 7 off on the LC III only (`rbv_clear`). A/UX
  writes $88 (SCSI) and $90 (ASC) to VIA2+$1A03; the LC III ROM's own handlers write
  exactly the same (ROM+$A05A, $A0DA, via VIA2 base $CEC). MAME (hardware-tested pseudo-VIA)
  clears on either.
- ProductInfo/VideoInfo: slot 0 found its display sResource unaided (unlike the 605's
  $51900000 VRAMLogAddr32).
- Console `initDFAC - unexpected machine type: 25`: `initHardware` names only the IIsi
  (0x10) and `devices[0]` = 2 (Quadras), but falls through to the same `setDFACByte` after
  the printf. Cosmetic.

**The patch** (`src/sonora.S`, 386 bytes over `orwellsize` + `memcdjsize` in pstart, up to
`_DAFBMonitorDetect`: Orwell/djMEMC RAM sizing, never called here; pstart is
identity-mapped, so no physical/virtual split):
1. `boardinit+0x14` → `sonora_switch`: 0x19/0x3C → 0x2e at the switch only.
2. `memsize+0x9c` (`tst.l rbv_exists`) → `jsr sonora_rbv`: Z set on Sonora, so memsize
   takes the one-bank path instead of the RBV one (bank A from 0 and bank B at $04000000,
   IIci layout, both unbounded probes).
3. `memsize+0xae` → `sonora_banksize`: the MEMCjr patch's bounded probe (Mac OS BufPtr
   rounded up to 1MB, bus error catch).
4. `vadrspace`'s `jsr setup_autovectors` → `sonora_vectors`: levels 3/5/6 → `nointr`, as on
   the 605 (no on-board source; Jeff's board is overclocked too).
5. `aEgretDispatch+2` → `sonora_egret`: return pbResult. The LC III ROM's XPRAM routine
   (ROM+$B37D6: type 1, cmd 2/8, `_EgretDispatch`, `lea $14(a7),a7; rts`) is the 605's
   ROM+$B37EC; d0 = 1 meant "failed" to ROM code in the kernel. No visible change in MAME
   (the A/UX desktop is 1-bit either way: the Toolbox's own setting).
cpuspeed stays the IIvx's 32: it only sizes SCSI timeouts, and suits 25 and 33MHz alike.
`CKPT=1` adds the checkpoint machinery (602 bytes): `_start`'s `jsr boardinit` →
`sonora_board`; keys 1-9, 0 = entry, boardinit, RAM sized, MMU on, then the init_first /
startup / initfunc trampolines as on the 605. In MAME: key 3 restarts at 3 and the Mac boots
again, key 0 at 10 (next boot fscks), no key boots to the Finder.

**Toolbox** (`src/toolbox-sonora.txt`): BoxFlag 0x15 (LC III) and 0x38 (LC III+) become
0x0C (IIsi), not 0x10: later Toolbox readers are `doVariables` (≥ 0x0C), the TimeDBRA set-up
(≤ 0x14 is all the same) and `cSysBeep` (0x10 takes `quadraSimpleBeep`, which only loads
`'snd '` 1 from another file; 0x0C the generic `cSndPlay`; that difference turned out to
matter, see v4), and 0x10 would tell System 7.0.1
it is on an 040 Quadra. The 36-byte site can't hold a second store, so the shared exit at
`GetLowFromKernel+0xa` becomes `move.b d1,BoxFlag` and the dispatch sets d1 = 0x10 before
the table, 0x0C before the LC III branches. Unicorn (68040), all 256 BoxFlags, original vs
patched 3.1 `Patch.067C`: only 0x15 and 0x38 change (to 0x0C); `realBoxFlag` and the stack
match. Also verifies on 3.0.1's `Patch.067C`.

**MAME 0.289 and the LC III.** `maclc3` (and `maclc3p`, `maclc520`) stop in the ROM's
Test Manager with a black screen: the ROM's CPU test (ROM+$47204) sets CACR bit 15 and
reads back $A000 (bit 15 kept: an 040's IE bit), so it takes the 030 for an 040, executes
`cinva` ($F498, "coprocessor 2 not present") and fails. `tools/mame-lc3.lua` turns that
`beq` into `bra` (ROM+$47218) and takes $700 off the ROM checksum, in MAME's copy only; it
also turns on the FPU setting (off by default; read at reset, so it resets two frames
later). A/UX sized 8MB there (BufPtr $7E9428); blamed on MAME's ROM here, but it was Mac
OS's 24-bit mode, see below.

**Results (MAME, A/UX 3.1 Shoebill image + `make-disk.sh --sonora --date --daynaport`):**
`maclc3` (25MHz, machineID 0x19) and `maclc3p` (33MHz, 0x3C) boot to the A/UX Finder. Not
run on hardware.

### 2026-10-29: first real LC III; RAM, sound (v2)
**v1 on Jeff's LC III** (25MHz board at 33MHz, 68882, 36MB, BlueSCSI): A/UX 3.1 to the
Finder. So real Sonora does answer at A/UX's $500xxxxx addresses. Console: `initDFAC -
unexpected machine type: 60`, i.e. machineID 0x3C: the board reports Gestalt 62 (LC III+).
Sonora makes the CPU clock, and its CPU ID follows the clock setting as MEMCjr's does; both
IDs were covered. Problems: `total memory size: 8388608` of 36MB; init "respawning too
rapidly" for `catsearchd`; no sound; DaynaPORT absent (the disk had no `--daynaport`).

**RAM.** System 7.1 on these Macs starts in 24-bit mode (MMU32Bit $CB2 = 0 in MAME), where
Mac OS uses 8MB and BufPtr sits below it, so `sonora_banksize`'s BufPtr limit stopped at
8MB (MAME the same: $7E9428). PhysMemTop ($1EF8 in launch's copy at kstart) is the end of
physical RAM in either mode (MAME 32MB: $2000000). The limit is now the larger of the two.
MAME: 32MB with 24-bit mode. (MEMCjr's `b605_banksize` has the same BufPtr-only limit: a
605 in 24-bit mode would get 8MB. Not changed.)

**catsearchd** (`csd:2:respawn:/etc/catsearchd`) `check_minmem`: `uvar` v_maxpmem (pages,
struct var +$C4) × 4KB against `minmem` = 16MB (`-m N[k|m|p]` sets it), else "insufficient
memory available" and exit 1. Stock behaviour on any A/UX Mac with less than 16MB;
reproduced in MAME at 8MB (11 exits), gone at 32MB.

**Sound.** Test: an inittab `once` line running `dd if=/unix of=/dev/snd/raw bs=8k count=40`,
MAME `-wavwrite`. v1: `dd` never returns, no samples written to the ASC. With `devices[0]` =
3 (the IIvx's, classic ASC) `ASCIntr` runs with $804 = $0E and refills only on bit 0 (FIFO
A half empty). MAME's Sonora ASC (checked with ASCTester on real hardware): FIFO A reads
empty in playback, half empty is bit 2, FIFO IRQ enables at $F09/$F29 (0 = on; reset 0;
Mac OS never wrote them after the chime). `devices[0]` = 2 (the Quadras' IOSB/EASC path:
`sndinit` programs the $F00 block, `ASCIntr` refills on bit 2 and toggles $F09/$F29):
`dd` completes, all 327,680 bytes go to the FIFO, but still silent. The DFAC is in the LC
III's output path (MAME `dfac.cpp`: ASC PWM → LPF, bit 1 → amplifier → attenuator, bits 7-5),
and A/UX's `initHardware` sends 0 then `setAGC`'s $08 through Egret (pseudo-command $0E,
byte bit-reversed by `reverse_bits`): volume -inf, LPF off. Mac OS's value: $6A (volume 3
= SdVolume $260, bit 1, AGC bits). Forcing $E2 into it in RAM: the noise plays.
Fix in the patch: `_start`'s `jsr boardinit` → `sonora_board` (devices[0] = 2 after the
IIvx case; works out the DFAC bits from SdVolume), and `cEgretDispatch`'s first instruction
(`link.l a6,#-12`) → `jmp sonora_cegret`, which puts bit 1 and SdVolume's bits into every
DFAC request ($0E, data byte bit-reversed: bits 6 and 2-0) before the link. `setDFACByte` is
in the `snd` boot.d module, which autoconfig relinks, so the filter sits in the core.
MAME, real patch: DFAC $6A under A/UX as under Mac OS, `dd` done, noise at -9dB; no
`initDFAC` message any more (`initHardware` takes the Quadra branch). 494 bytes (checkpoint
build 702).

**DaynaPORT on the 5380.** `scsireq`/`scsichar` dispatch through `scsitab` to the 5380
driver (`c80_*`); `c80_char` keeps the flags in `tasks[]` but nothing reads SDC_RDPOLL.
`scsi_vio` loops on what `scsi_in` returns, and `scsi_in` wraps its pseudo-DMA in `setjmp`
(a target that stops early ends the transfer with a bus error), so short reads look
handled. Untested; MAME has no DaynaPORT.

**v2** on Jeff's SD card as `HD0_aux31-lc3-v2.hda` (`--sonora --date --daynaport --ip
192.168.1.51`; v1 kept as `_HD0_aux31-lc3-v1.hda`). MAME `maclc3p`: Finder, 32MB, DaynaPORT
driver loads ("no DaynaPORT found"), catsearchd stays up.

### 2026-10-29: v2 on the real LC III; sound to both FIFOs (v3)
**v2 on Jeff's LC III:** all 36MB (so on-board RAM and SIMM are one contiguous bank),
DaynaPORT works over the 5380, video 640×480 at thousands of colours with 768KB VRAM and
256 with 512KB (Apple's figures). Sound: none; the Sound control panel flashes the menu bar
(`cSysBeep`'s flashBar: volume 0, no 'snd ' resource, or `cSndPlay` failing) with the slider
above 0. `dd if=/unix of=/dev/snd/raw bs=8k count=8` returns at once (64KB fits the driver's
buffer) with no sound, so the kernel path is silent too.

**Testing the Toolbox in MAME.** Driving the Finder by keyboard (`natkeyboard` for letters,
fields for Command and arrows; `manager.machine.time.seconds` is whole seconds, use
`time:as_double()`) opens the Sound control panel, but arrowing through it plays nothing,
and a failed Find gives a dialog, not a beep. What works: a breakpoint at `cGetOSEvent`
(0x6A38 in `Patch.067C`, keyed on its own bytes, since other processes run code at the same
address and the u-area can't be read from user mode) that pushes the return address and
jumps to `cSysBeep` (0xABCC), armed from Lua with an arrow key to wake the Finder. Each
beep goes `cSysBeep` → `setSndVol` → `cSndPlay` → `cSndNewChannel` → `cSendToKernel` →
`writeToKernel` → kernel → ASC, with no system call errors.

**Cause.** MAME's `-wavwrite` has three channels; the ROM's chime is on the first two,
A/UX's sound only on the second. On the Quadra path (`devices[0]` = 2) `sndintr` writes
each sample to FIFO B only (`cmpi.b #2,devices; beq` past the FIFO A write, sndintr+0x352);
the classic path and the LC III ROM's chime (ROM+$45F28: `move.b d0,(a6); move.b
d0,$400(a6)`) write both. Sonora plays A and B as the two channels and the LC III's speaker
takes A. Fix (`src/snd-sonora.txt`): that `beq` becomes a `nop`, in `/unix` and in
`/etc/boot.d/snd` (a relocatable COFF object; the `beq.b` is PC-relative, so the same two
bytes) so an autoconfig relink keeps it. FIFO A is still skipped while sound input records
(asc_state bit 2). MAME: the injected beeps on both channels. **v3** on Jeff's SD card as
`HD0_aux31-lc3-v3.hda` (v2 kept as `_HD0_aux31-lc3-v2.hda`).

The LC III ROM programs Sonora like an EASC for the chime (version $Bx: $F09/$F29 = 1,
$80A = 2, FIFO clear, $806 = $E0, mode 1, rate $812F and CD-XA coefficients in both $F00
blocks, channel volumes $7F, $F08/$F28 = $80), close to what `sndinit`'s Quadra branch writes.

### 2026-10-29: v3 on the real LC III; Simple Beep (v4)
**v3 on Jeff's LC III:** sound plays, every alert sound but Simple Beep, and A/UX's volume
slider works live: real Sonora applies ASC $806 (A/UX's `sndioctl` volume write), which
MAME's Sonora ignores.

**Simple Beep** is `'snd '` 1, a square wave (the other alert sounds are sampled). On the
Quadra path the kernel has no wavetable synthesizer: `sndopen` sends `/dev/snd/note` and
`/dev/snd/wave*` to EIO when `devices[0]` = 2 (sndopen+0x37e). `cSysBeep`, for alert ID 1,
dispatches on BoxFlag: the Quadras (0x0E, 0x10, 0x14, 0x18, 0x1D, 0x1E, 0x2E, 0x2F, 0x35) go
to `quadraSimpleBeep`, which plays `'snd '` 1 from `/mac/lib/Resources/sampledBeep`; the
LC III's 0x0C is below the table and got the square wave → `cSndPlay` fails → flashBar
(MAME, forcing the alert ID read at cSysBeep+0x40 to 1: reproduced). Fix
(`src/toolbox-sonora.txt`): the table's out-of-range `bhi.w` (cSysBeep+0x78) goes to the
`quadraSimpleBeep` call instead of the square wave. MAME: the sampled beep on both
channels. **v4** on Jeff's SD card as `HD0_aux31-lc3-v4.hda` (v3 kept as
`_HD0_aux31-lc3-v3.hda`).

**v4 on Jeff's LC III:** every sound plays, Simple Beep included, also when clicked in the
Sound control panel (expected silent there, as the panel was taken to play the System's
square wave itself; it evidently goes through `SysBeep`). Shutdown and restart work.

## Networking: DHCP, and MacTCP under A/UX (2026-10-31)

A/UX 3.1 has no tool for setting up TCP/IP beyond `newconfig`, which asks for an Ethernet
card's address and netmask once, while it builds a kernel (`/etc/startup.d/ae6 -i`), and
never for a gateway or DNS servers. The MacTCP control panel configures nothing under
A/UX: it's MacTCP 1.1 without its `.ipp` driver. The Toolbox patches
(`/mac/lib/Patches/Patch.0178`, `.067C`) have one of their own (`mactcpdrvr.c`, `tcp.c`,
`udp.c`) on A/UX's sockets, reading the interface's address with an ioctl and DNS from
`/etc/resolv.conf`, so Mac programs follow whatever A/UX is set to.

DHCP works from an ordinary UDP socket (tried on the 605's DaynaPORT): with the interface
at 0.0.0.0, broadcast 255.255.255.255 and no other default route, the DISCOVER leaves
through it and the server's broadcast reply comes back in. A/UX takes 0.0.0.0 as an
address; the kernel widens its netmask to the class's (255.0.0.0), and its network route
is the default route. netsetup's `dhcpc` does this at boot: on the 605, a `--daynaport`
disk made without `--ip` had dp0's address from the router at its first start. Details,
and A/UX's ioctl numbers (not 4.3BSD's), are in aux-3-ports' decisions ("netsetup"). A/UX's `ifconfig` can't take 255.255.255.255 (inet_addr gives -1),
and `route` exits 1 even when it worked. `nslookup` (BIND 4.8's) times out against a
UniFi router whose DNS the libc resolver uses fine; not looked into.

## 2026-11-01: Mac patches as groups built from modules; `--enabler`

**Why.** The Color Classic II (below) is Sonora, the LC III patch's board, with Cuda, the
605 patch's system controller. The two patches were separate kernels with code copied
between them (the `_EgretDispatch` result hook, the interrupt vectors, the bounded RAM
probe, the checkpoint code). They can't be stacked on a disk: both redirect the same call
sites (boardinit's switch, `_start`'s `jsr boardinit`, `setup_autovectors`, memsize's
banksize call, `aEgretDispatch+2`), and binpatch checks each site's original bytes. Nor can
one kernel serve every Mac: the Cuda transport takes 1,924 of the 2,028 bytes of the Egret
driver it replaces, so an Egret Mac would lose its clock, PRAM, ADB and soft power; keeping
both needs about 2KB more, and the space over `orwellsize` (766 bytes to
`_DAFBMonitorDetect`) holds the Sonora hooks (494). So: one patch per group of Macs, a
group being a board module with Egret or with Cuda, put together from shared source when
it's built. (Jeff, 2026-11-01.)

**Layout.** `modules/common/hooks.S` holds macros (`CKPT`, `EGRET_RESULT`,
`NOINTR_VECTORS`, `BANKSIZE`, `CKPT_CODE`); `modules/memcjr/memcjr.S` and
`modules/sonora/sonora.S` are board modules (their hooks and `ourmac`, the test for the
group's Macs); `modules/cuda/cuda.c` calls `ourmac`. A group's `src/GROUP.S` defines
`IFOURMAC` (its machineIDs) and includes `hooks.S` and its board module. That makes one
assembly unit, so calls to `ourmac` stay short `bsr`s and the code lands where it did;
`src/kernel.ld` places the sections; `kernel-patch.py`, `build.sh` and `apply.sh` as before,
the enabler step shared as `tools/put-enabler.sh`. Groups are named after Macs (`q605`,
`lc3`), modules after chips.

**Verified.** Both groups' `bin/kernel.txt`: identical to the old `kernel-605.txt` and
`kernel-sonora.txt` but for the two header comment lines. Checkpoint builds: q605's .text,
.text2 and .text3 the same sizes (`ckpt_capture` and `ckpt_restart` swapped places); lc3's
714 bytes (was 702), as it now takes all 20 checkpoint keys. Disks from the old
`make-disk.sh` (`--memcjr`, `--sonora`) and the new (`--enabler`), same enabler and
`--date`: identical but for the HFS volume's last-modified date and the same date in its
catalog. Not booted, since the bytes are the same.

**`--enabler`** (Jeff's choice, 2026-11-01): the System Enabler picks the group.
`tools/enabler.py` reads the enabler's `gbly` resource: a version word (1), a long, a count
word, then the BoxFlags as words. Enabler 065 1.2 lists 0x53 0x54 0x58 0x59 (the 475 and
605 at each speed) and 0x56 (the LC 575, not supported); 003 1.1 lists 0x15 0x38; 403 1.0.2
lists 0x4b 0x32 0x4d 0x4a. A group is chosen if the enabler lists any of its BoxFlags
(`BOXFLAGS_GROUP` in `make-disk.sh`). The enabler still goes into the System Folder as
"System Enabler NNN", the number from its file name. `--memcjr` and `--sonora` still work,
with their own enablers only. 003 1.0 (0x15 alone) is still accepted: it's fine on an LC III
at 25MHz.

**The 605's RAM probe** stopped at BufPtr alone (the 24-bit mode fix went into the Sonora
copy only). It stayed so through the refactor, which then changed no bytes; afterwards the
605 took the shared `BANKSIZE`. The only change to its kernel is the PhysMemTop test, 10
bytes in `b605_banksize` (.text 1934 of 2028 bytes, the checkpoint build 1990); the code
after it is the same, moved up. The 605 and 475 do run System 7.1 in 24-bit mode (32-bit
addressing is a Memory control panel setting on them, on by default), where A/UX had 8MB
whatever was fitted. In 32-bit mode BufPtr and PhysMemTop round up to the same 1MB, so
nothing changes there. On Jeff's 605 (`HD0_aux31-605-ram.hda`: `--enabler` 065,
`--daynaport`, `--date`, `--pkg`), with 32-bit addressing on, A/UX boots with all its RAM,
as before. Not yet run with 32-bit addressing off.

**Color Classic II, LC 520, LC 550** (Sonora with Cuda). Linux `config.c` gives the Color
Classic II the LC III's types but `MAC_ADB_CUDA`. The LC III's ROM (`ecbbc41c`, $067C) has
its ProductInfo pointers at ROM+$D2780 (17, self-relative): Sonora-decoder (kind $0B)
records for Gestalt 27 (LC III, CPU ID word $0001 at +$3C), 62 (LC III+, $0003), 28, 40, 41
and 42, none for 56, 80 or 83. MAME's `maclc520` and `maclc550` use `ede66cbd.rom` (not
here), `mactv` `eaf1678d`; MAME has no Color Classic II. Enabler 403 1.0.2 lists 0x32 (LC
520, Gestalt 56), 0x4a (LC 550, 80), 0x4d (Color Classic II, 83) and 0x4b (Gestalt 81,
unknown: perhaps a clock variant, as with the LC III+): machineIDs 0x36, 0x4e, 0x51, 0x4f.
Plan: a group with the Sonora module over `orwellsize` and the Cuda transport over the
Egret driver (the two spaces don't overlap), the DFAC filter ahead of `cuda_dispatch`
(`sonora_cegret`'s hook, cEgretDispatch's first instruction, is gone with the Egret code),
the Toolbox's 0x32 and 0x4a-0x4d to 0x0C, enabler 403; first in MAME's `maclc550`.

## Open items
- A Sonora + Cuda group (LC 520, LC 550, Color Classic II): see 2026-11-01. MAME needs
  `ede66cbd.rom`.
- A real 605 with 32-bit addressing off: the shared `BANKSIZE` should size all its RAM.
- LC III: a 25MHz board (Gestalt 27) and the Performas on real hardware; sound input, the
  floppy drive and the serial ports (found by the kernel, not exercised). The DFAC volume
  is set once from Mac OS's SdVolume while A/UX's control drives ASC $806, so a low Mac OS
  volume at startup also lowers A/UX's loudest setting.
- Real 605 (33MHz): A/UX 3.1 boots to the Finder with correct video at every depth (v7).
  A/UX's `_EgretDispatch` returning 1 for success is fixed on the 605 and (Sonora patch)
  the LC III / III+ only; other Egret machines have the same convention, not touched.
- The q605 patch (MEMCjr) is for the Quadra 605, and in theory the LC/Performa 475 (MAME only, see
  above); A/UX's Egret machines (IIsi, IIvi, IIvx, Performa 600, Q900, Q950) must use
  unpatched media (the kernel guard only keeps it harmless there).
- A real 475 (with a full 68040): first run, ideally with the checkpoint kernel at hand.
- Deliverable (Jeff, 2026-10-29): `tools/make-605-disk.sh` patching an existing, installed
  A/UX 3.1 HD image into a 605 disk. No install-from-media flow and no patched install media,
  so there is no installer to restrict to the 605.
- Toolbox VideoInfo pointer (see above): exercise Monitors / depth changes, sound, shutdown
  and restart in the Toolbox; if anything reads VideoInfo, patch `UI_get_prodinfo`.
- Real 605 hardware: MEMCjr RAM sizing by probing past the end of RAM (see step 5 above),
  Cuda timing, DAFB-in-MEMCjr register writes.
- Disassemble `launch` / A/UX Startup for any machine checks and the kernel-info layout.
- Base version: **3.1** (Jeff, 2026-10-28 late; was 3.0.1). Patches are written against
  symbol names and instruction patterns; the same tools also build for 3.0.1.
- A/UX 3.0 (`Apple_UNIX.iso` in `AUX_3_Use_in_Shoebill.zip`) is not supported (Jeff,
  2026-10-30): no `memcdjsize` or Cuda in its kernel, and its System 7.0.x is too old for
  Enablers 065 and 003. No spec verifies on it; `make-disk.sh` reads `/etc/RELEASE_ID` and
  refuses any release but 3.1 by name.
