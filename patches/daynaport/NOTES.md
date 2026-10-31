# DaynaPORT SCSI/Link for A/UX 3.1

*Developer notes. To set up networking, see this patch's [README](README.md). Paths below
are relative to this folder, except `tools/`, which is the repository's.*

Goal: a network interface for the DaynaPORT SCSI/Link that BlueSCSI V2 emulates over Wi-Fi.
No A/UX driver exists. Reference design: Jeff's Linux driver
(github.com/jflitton/daynaport-scsilink-linux-driver, faster than NetBSD's `dse`); its
protocol header is vendored as `src/daynaport.h` (commit 0be62ed, unchanged; relicensed MIT
here by its author).

## Status

0.2 (`src/dayna.c`): attaches `dp0`, an Ethernet interface with ARP and IP; ping,
telnet and ftp work on the 605 (2026-10-29), about 120 KB/s; the attempts to do better
are under Throughput. 0.1-probe (one READ/WRITE test at boot) worked there too, below.
Disk: `make-disk.sh ... --daynaport`, or `apply.sh DISK [IP [NETMASK
[GATEWAY [DNS]]]]` on a copy of any A/UX 3.1 disk, links `dp0` into `/unix` on the host,
so the first boot needs no relink and restart; with IP it also writes `NETADDRS` and
`resolv.conf` as netsetup would, and without, puts `dp0` in `/etc/dhcpc.conf` for DHCP.
netsetup (aux-3-ports) sets dp0 up afterwards and gets its DHCP leases; the patch bundles
its package. It replaced `/etc/dpsetup` on 2026-10-31.

DNS needs nothing from the driver: 3.1's libc has the BIND 4.8 resolver, which telnet, ftp
and ping link statically. `gethostbyname` tries `res_search` (servers from
`/etc/resolv.conf`: `nameserver`, up to three, and `domain`; no `search`) and on any
failure falls back to NIS, then `/etc/hosts`. A `nameserver` that doesn't answer makes
every `/etc/hosts` lookup wait out the timeouts first. `nslookup` is
`/etc/bind/tools/nslookup`.

## The driver

- `daynainit` (init-last) finds the adapter, sets `SDC_RDPOLL` on it, sends ENABLE, waits
  half a second, reads the MAC with STATS and `if_attach`es `dp0` (`IFF_BROADCAST |
  IFF_NOTRAILERS`, MTU 1500). The search: the INQUIRY replies `ss_init` kept (below),
  checked with one INQUIRY of that bus/id; failing that, INQUIRY of targets 0-6 on bus 0.
- `/etc/startup.d/dayna` (`src/startup`) configures it at boot from its
  `/etc/NETADDRS` line, `dp0 address broadcast [netmask [gateway]]` (the gateway, an
  addition, becomes the default route), as `/etc/startup.d/ae6` does for `ae` cards.
  autoconfig puts a `/etc/startup.d/<module>` line in `/etc/startup` for every module that
  has such a script. With no `dp0` line it does nothing: either dp0 is in
  `/etc/dhcpc.conf`, and `netsetup boot` (from `/etc/inittab`, after `/etc/rc`) gets it
  an address by DHCP, or it isn't set up.
- One command at a time on the target. `dp_run`, called only through `softcall` (softint
  runs at IPL 0), finishes the completed command and issues the next: a queued frame
  first, except that a due READ goes before a second WRITE in a row. The SCSI Manager's
  completion routine and the poll callout (run by `timein` at spl5) only set flags and
  softcall `dp_run`, so it never runs in `c94_callback` and `spl2()` never lowers the IPL.
- Receive, as the Linux driver: READ(6) of 4096 bytes (flag 0xC0) into a zeroed buffer
  walked by `daynaport_rx_parse`; a READ that brought frames is followed at once by
  another; after an empty one, the next comes `dayna_poll0` ticks later while
  `daynaport_poll_fast` holds (frames to us within `dayna_fast_hold` polls), else
  `dayna_poll`. Defaults 1 and 4 ticks (20 and 80 ms at 60 Hz), 16; globals, as is
  `dayna_debug` (a line every 256 READs).
- Frames: IP goes on `ipintrq` (`softcall(ipintr, 0)`), ARP to `arpinput`, each as an
  mbuf chain led by the `ifnet *`, clusters (MCLGET, open-coded as in ae6) for anything
  over one mbuf. Other types are dropped, as are IP and ARP while there is no address.
- Output (from ae6_output): `arpresolve`, then an Ethernet header in front, `if_snd`,
  softcall. Broadcasts are copied to `loif`, as ae6 does; AF_UNSPEC carries ARP's
  own header. Sends are padded to 60 bytes and use blind transfers (a WRITE's length is
  exact, so the 53C96 driver's blind loop is safe there).

## How A/UX loads it

- `boot.d` modules are plain COFF objects (magic 0x150, a.out header 0410, `.text` at 0,
  `.data` at 0x400000, `.bss` after it), linked into `/unix` by `autoconfig` with
  `/etc/config.d/newunix`. Every relocation in A/UX's own modules (devscsi, cslip, ae6,
  bnet) is type 17: the 32-bit field gets (final address − the symbol's value in the object)
  added, so the field holds the target as the object lays it out (a common symbol's value is
  its size, an undefined one's 0). `Coff.link` (`tools/coff.py`) implements this and
  reproduces Apple's link of devscsi in the 3.1 kernel byte for byte (.text 2252, .data 368).
- `tools/elf2coff.py` turns `m68k-elf-ld -r` output (`src/module.ld`) into such an
  object, resolving PC-relative references inside a section; `verify` links both forms at
  the same addresses and compares, `undef` checks the module's needs against a `/unix`.
- `/etc/master.d/dayna`: `include .` and `spl - dayna - - -`: a software module whose
  `daynainit` runs from `init_last` in `main()` (after the daemons are forked, just before
  `sched()`), so interrupts are on and process 0 may sleep. master(4) calls init-last `p1`;
  autoconfig's parser takes `p` + `f`/`s`/`n`/`0`/`l` and rejects `1` ("Flag '1' not
  supported", seen on the 605). Flag `n` would instead put a
  probe/attach pair in `ubdinit`, which `BNETinit` runs at `pn`, before interrupts.
- `sysinitrc`'s `autoconfig -a` relinks only for NuBus changes, not for a new module.
  Earlier test disks spliced a relink into `/etc/startup` (`autoconfig -v -o /unix -S
  /etc/startup -M /etc/master`, sync, reboot), which cost a restart on the first boot.
- `tools/linkmod.py` now does that link on the host. autoconfig runs ld with newunix at its
  own addresses (pstart, `.text` 0x10000000, `.data` 0x11000000, `.bss` 0x12000000) and the
  modules' sections after it, so the core never moves; after the last module's `.bss` come
  all the commons nothing defines. It then fills in tables in pstart and `.data`:
  `sectinfo` (vaddr, paddr, size of `.text`, `.data`, `.bss`; each loads page-aligned after
  the one before, as the section headers' paddr say), the `init_first`...`init_last`
  arrays (64 slots, null-terminated; core entries first), `cdevsw`, `fmodsw`,
  `forkfunc`/`execfunc`/`exitfunc`, `resetfunc`, and a 256-byte MODULES record per module
  (name, major or -1, 2, flags with `s` = 0x80, prefix, units; then stale buffer bytes,
  the same in every record). Symbols: core locals, the modules' locals without their
  `.data`/`.bss` section symbols, core globals, module globals; each `.file` points at the
  next, the last at the first global; strings in symbol order. Linking dayna onto the end
  of a configured `/unix` is then what autoconfig makes with dayna last, except that
  dayna's `.bss` follows the commons (dayna has none of its own). `linkmod.py check`
  takes ufs, the last module, out of Apple's 3.1 `/unix` and links it back: identical, all
  837678 bytes. The disk also gets the lines autoconfig keeps for dayna in `/etc/master`
  (`dayna - - dayna -1 -1 0`) and `/etc/startup` (`/etc/startup.d/dayna $IFLAG -C 0 -D 0`,
  after bnet's). A later relink by autoconfig itself takes dayna from `boot.d` as before.
- `tools/ufsput.py` writes the files into the UFS root (direct and single indirect blocks,
  enough for `/unix`; 4.3BSD accounting: nbfree/rotational tables for whole blocks,
  nffree/frsum for fragments) and checks a partition like fsck passes 1 and 5. The 3.1 root
  checks clean; A/UX leaves the superblock's `fs_cstotal` as mkfs wrote it (only the cgs
  and csum area are maintained).

## Kernel interfaces (3.1)

- SCSI Manager: `scsireq((bus << 8) | target, req, 0)` queues and returns 0; on completion
  the manager calls `req->faddr(req)` from `c94_callback`, which then restarts the chip, so
  the next command is better issued from a `softcall` than from the callback. A second
  request for a busy target is queued on its list (`c94_req`), not refused. `databuf` and
  `sensebuf` are physical (`realvtop(5, va)`, as devscsi does); `struct scsireq` is 0x218
  bytes. Timeout 0 means one second per KB plus one.
- 53C96 data in (`c94_in`): multiples of 256 bytes are read blind, the rest polled. A READ
  that ends early (any DaynaPORT poll) would leave the blind loop waiting, so the adapter's
  target gets `scsichar(id, SDC_RDPOLL, SDC_RDPOLL)`: `c94_vio` then uses `c94_pollin`.
- 5380 data in (the LC III with the Sonora patch; the SE/30 and II family): `scsichar`
  reaches `c80_char`, which keeps the flag in `tasks[]` unused. `scsi_in` wraps its
  pseudo-DMA in `setjmp`, so a READ that ends early stops the transfer with a bus error and
  `scsi_vio` takes the count it got. Works on an LC III (2026-10-29).
- `scsichar` and `scsireq` take `(bus << 8) | target`, the bus being the `scsitab` index
  (1 for the 605's only bus) and checked against `curscsi` (`knowndriver`); bus 0 means
  the bus a search found the target on (`searchtab`).
- `softcall(f, a)` queues f(a) once (a pending pair is not queued again) for `softint`,
  which runs at IPL 0. `timeout(f, a, ticks)`/`untimeout(f, a)` are 4.3BSD's; `timein`
  runs callouts at spl5. `spl0`-`spl7` set the IPL outright, so they can lower it.
- Network: 4.3BSD-Tahoe style. `struct ifnet` 0x54 bytes, `arpcom` follows; mbufs of 128
  bytes (`m_off` at 4, `m_len` 8, `m_dat` 0xc, `m_act` 0x7c). Input goes on `ipintrq` with
  the `ifnet *` prepended (`ipintr` and `arpinput` strip it), then `softcall(ipintr, 0)`
  (`schednetisr`). `splimp` = `splnet` = `spl6`. Kernel functions return pointers in a0 and
  d0. No `memcpy`/`memset` in the kernel (`bcopy`, `bzero`, `bcmp` are there). HZ is 60.
  The kernel `printf` has no field widths.

## Probe on the 605 (2026-10-29, BlueSCSI V2 2.0f at id 5, bus 1)

Module linked by autoconfig and ran at init-last. INQUIRY of ids 0-6: disks at 0 and 2,
SST_SEL ("Cannot select SCSI device") on the empty ids. Receive buffer physically
contiguous; characteristics were 0; ENABLE good; MAC 00:80:19:a3:88:53 (Dayna's OUI, not
a Wi-Fi MAC). 40 READ(6) of 4096 bytes in 134 ticks (120 of them the test's own gaps): all
returned 0 (a short read is not SST_LESS), an empty one 6 bytes; 3 broadcast frames, 668
bytes, the first IPv4 from b8:06:0d:32:96:ff. WRITE(6) of 60 bytes: good. So `datasent` is
the true response length (the "count matched" figure was cut off at the window's edge).

## The kernel's own scan

`ss_init` (boot) INQUIRYs every id of every bus and keeps the replies: `ss_context`
(.bss, 0x536 bytes per bus, at most 4 buses): word 0 the bus number (0: unused), then at
+4 one 36-byte INQUIRY buffer per id 0-6, type byte 0xff where nothing answered;
`ss_vendorinfo` prints the "SCSI bus 1, id 5: CPU : Dayna SCSI/Link 2.0f" lines from it.
Both symbols are static, so a module cannot link to them; `ss_init` (global) loads the
address with `movea.l #ss_context,a0` (207c, at ss_init+0xd4 in 3.1, after `muls.l
#0x536,d0`). The driver checks those ten bytes, reads the address and falls back to its
own scan if they differ.

## Throughput

0.2 on the 605: about 120 KB/s sustained (Jeff's Linux 2.0 driver: 250 down, 330 up).
A/UX's TCP (in the bnet module) is more cautious than Linux's:

- `tcp_sendspace` and `tcp_recvspace` are 4096, so a sender has under three segments in
  flight and then waits for an ACK that leaves only after the next READ.
- `tcp_mss` rounds `if_mtu - 40` down to a multiple of MCLBYTES (1KB on A/UX), so
  Ethernet segments are 1024 bytes, not 1460; with BlueSCSI's two frames per READ that
  is 2KB a READ instead of 2.9KB. Hosts off the local networks get `tcp_mssdflt`, 512.
- `sbreserve` allows up to 0xcccc bytes; NMBUFS=1000 gives 128 clusters, two per 1460
  byte segment. BlueSCSI's ring holds 20 frames.

Tried on the 605 (2026-10-29), none kept; 0.2 and stock TCP stay:

- A bnet patch (`patches/bnet-tcp.txt`, removed since; in git at 7b617ea) skipping the
  rounding, with 16KB buffers and a 1460 default. About 140 KB/s.
- 0.3, the Linux 2.4 driver's arbitration (up to 16 WRITEs while frames are queued, then
  one READ): 110 KB/s down, 140 up. During a download: 256 reads/140 ticks = 109 reads/s,
  135 empty, 241 frames, 119 writes. The productive READs carried 1.99 frames each
  (BlueSCSI's cap), but over half were empty: with 4KB in flight the peer stops every four
  segments for our ACK, and after an empty READ the next waits for a clock tick.
- 0.4, 0.3 plus up to four empty READs reissued at once after frames came in or went out:
  97 KB/s down.

## Open

- EtherTalk (802.3 frames to `etintrq`, as ae6 does) is not done; nor multicast.
- Polled 53C96 reads cost CPU per byte; the Mac driver's header-then-body split could be
  done with a `DMA_CALL` vio entry if it matters.
