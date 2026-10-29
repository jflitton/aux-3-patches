# DaynaPORT

`--daynaport` · A/UX 3.1 · Tested on the Quadra 605

A driver for the DaynaPORT SCSI network adapter, which a BlueSCSI or ZuluSCSI with Wi-Fi
emulates.
It gives A/UX TCP/IP networking (`ping`, `telnet`, `ftp`) at about 120 KB/s, and does
nothing if there's no adapter.

## Network settings

Optional. You can also leave them out and run `/etc/dpsetup` on the Mac once instead.

| Option | Default |
|---|---|
| `--ip ADDRESS` | none |
| `--netmask MASK` | `255.255.255.0` |
| `--gateway ADDRESS` | the IP address ending in `.1` |
| `--dns ADDRESS` | the gateway |

## Setting up Wi-Fi

Turn on the DaynaPORT emulation and Wi-Fi as your device's guide describes:
[BlueSCSI](https://bluescsi.com/docs/WiFi-DaynaPORT) or
[ZuluSCSI](https://github.com/ZuluSCSI/ZuluSCSI-firmware/wiki/WiFi-DaynaPORT-Ethernet-emulation-for-Classic-Mac-OS).
Skip the guides' Mac OS software steps (MacTCP, Open Transport); under A/UX, this patch
does that job.

## On the Mac

In CommandShell:

- `/etc/dpsetup` sets or changes the network settings. Press Return to accept a value in
  [brackets]. They take effect at once and at every start.
- `/usr/etc/ping 192.168.1.1 64 3` checks the connection.
- `passwd` sets a password for `root`. Do this before joining a network you share.

## Compatibility

| | Tested | Not tested yet |
|---|---|---|
| **Mac** | Quadra 605 | Other Macs that A/UX supports |
| **Adapter** | BlueSCSI or ZuluSCSI with Wi-Fi | Other DaynaPORT emulators, a real DaynaPORT |
| **A/UX disk** | `AUX_3_1_1GB_Use_In_Shoebill.zip` | Other A/UX 3.1 disks |

Quadras and Centrises use the same SCSI chip as the 605, so they're the likeliest to work;
the SE/30 and II family use a different one. No AppleTalk over Wi-Fi.

## Troubleshooting

Type `/etc/ifconfig dp0` in CommandShell:

- **No such interface:** A/UX didn't find the adapter. Check its setup against your
  device's guide (above).
- **No `inet` address, or names don't resolve:** run `/etc/dpsetup`.

**"Already has the DaynaPORT network driver":** start from the original disk image.

## For developers

| File | What it is |
|---|---|
| `apply.sh DISK [IP [NETMASK [GATEWAY [DNS]]]]` | Applies the patch to a copy of a disk image |
| `build.sh KERNEL OUTDIR` | Builds `bin/` from `src/` (needs the m68k-elf cross compiler) |
| `src/dayna.c` | The driver, `dp0`, an A/UX `boot.d` module |
| `src/daynaport.h` | The DaynaPORT protocol, from the Linux driver, unchanged |
| `src/aux.h` | The A/UX kernel interfaces the driver uses |
| `src/module.ld` | Linker script for the module |
| `src/master` | Its `/etc/master.d` entry |
| `src/startup` | `/etc/startup.d/dayna`: brings `dp0` up from `/etc/NETADDRS` at every start |
| `src/dpsetup` | `/etc/dpsetup` |
| `bin/dayna` | The driver module |
| `NOTES.md` | How the driver works and is linked into `/unix`; speed trials |

Based on Jeff Flitton's
[DaynaPORT driver for Linux](https://github.com/jflitton/daynaport-scsilink-linux-driver)
(GPL version 2), relicensed here under the MIT License by its author.
