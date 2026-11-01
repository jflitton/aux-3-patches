# DaynaPORT

`--daynaport` · A/UX 3.1 · Tested on the Quadra 605 and LC III

A driver for the DaynaPORT SCSI network adapter, which a BlueSCSI or ZuluSCSI with Wi-Fi
emulates.
It gives A/UX TCP/IP networking (`ping`, `telnet`, `ftp`) at about 120 KB/s, and does
nothing if there's no adapter.

## Network settings

Optional. Leave them out and the Mac gets its address by DHCP from your router, as other
computers do.

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

The disk also gets netsetup, which sets up the network. In CommandShell, as root:

- `netsetup` shows the settings and the address dp0 has now.
- `netsetup dp0 dhcp` gets dp0's address by DHCP.
- `netsetup dp0 192.168.1.50 gateway 192.168.1.1 dns 192.168.1.1` sets it by hand.
- Type `netsetup` and press Command-K for a dialog that does the same.
- `/usr/etc/ping 192.168.1.1 64 3` checks the connection.
- `root` has no password: set one with `passwd` before joining a network you share.

Changes take effect at once and at every start. Change dp0 at the Mac itself, not over
telnet: the connection drops when the address changes. netsetup is also a package for
pkg, and `pkg upgrade` keeps it up to date if you have pkg (`--pkg`).

## Compatibility

| | Tested | Not tested yet |
|---|---|---|
| **Mac** | Quadra 605, LC III (each with `--enabler`) | Other Macs that A/UX supports |
| **Adapter** | BlueSCSI or ZuluSCSI with Wi-Fi | Other DaynaPORT emulators, a real DaynaPORT |
| **A/UX disk** | `AUX_3_1_1GB_Use_In_Shoebill.zip` | Other A/UX 3.1 disks |

It has worked with both of A/UX's SCSI drivers: the 605's 53C96 (the Quadras' and
Centrises' chip) and the LC III's 5380 (the SE/30's and II family's). No AppleTalk over
Wi-Fi.

## Troubleshooting

Type `/etc/ifconfig dp0` in CommandShell:

- **No such interface:** A/UX didn't find the adapter. Check its setup against your
  device's guide (above).
- **No address, or names don't resolve:** `netsetup` shows what's wrong. With DHCP, see
  `/usr/adm/dhcpc.log`; DHCP needs a router that answers, as home routers do.

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
| `bin/dayna` | The driver module |
| `bin/netsetup-*.pkg` | The netsetup package, from aux-3-ports |
| `update-netsetup.sh AUX-3-PORTS` | Builds that package in an aux-3-ports checkout and copies it here |
| `NOTES.md` | How the driver works and is linked into `/unix`; speed trials |

Based on Jeff Flitton's
[DaynaPORT driver for Linux](https://github.com/jflitton/daynaport-scsilink-linux-driver)
(GPL version 2), relicensed here under the MIT License by its author.
