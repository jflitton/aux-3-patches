# A/UX 3 patches

Patches for A/UX 3, Apple's Unix for 68k Macs. Pick the ones you want, and one command
makes a patched copy of an A/UX disk image. Your original image is never changed, and no
Apple software is included.

| Patch | Option | What it does | A/UX | Macs |
|---|---|---|---|---|
| [MEMCjr](patches/memcjr/README.md) | `--memcjr ENABLER` | Runs A/UX on the Quadra 605, and in theory the LC/Performa 475 | 3.1 | Quadra 605 with a full 68040; LC 475 and Performa 475/476 untested |
| [Sonora](patches/sonora/README.md) | `--sonora ENABLER` | Runs A/UX on the LC III and LC III+ | 3.1 | LC III, LC III+, Performa 450/460/466/467 with an FPU; tested on an LC III at 33 MHz |
| [DaynaPORT](patches/daynaport/README.md) | `--daynaport` | Networking over a BlueSCSI's or ZuluSCSI's Wi-Fi | 3.1 | Tested on the Quadra 605 and LC III |
| [Date](patches/date/README.md) | `--date` | `date` works with years after 1999 | 3.1 | Any |

## Requirements

- macOS or Linux, with Python 3.9 or later.
- hfsutils and unar, for `--memcjr` and `--sonora` (`brew install hfsutils unar` on macOS).
- An A/UX 3.1 disk image. Tested with `AUX_3_1_1GB_Use_In_Shoebill.zip`, widely archived
  online; pass the zip or the `.dsk` inside it. (`AUX_3_Use_in_Shoebill.zip` is A/UX 3.0,
  which won't work.)
- Whatever your patches need (see their pages).

## Usage

    ./make-disk.sh AUX-IMAGE NEW-DISK PATCHES... [--ip ADDRESS ...]

A Quadra 605 disk with every patch, and an LC III disk:

    ./make-disk.sh AUX_3_1_1GB_Use_In_Shoebill.zip HD0_AUX.hda \
        --memcjr System_Enabler_065_12-sea.bin --daynaport --date --ip 192.168.1.50
    ./make-disk.sh AUX_3_1_1GB_Use_In_Shoebill.zip HD0_AUX.hda \
        --sonora System_Enabler_003_1.1.sea.bin --date

`--help` lists every option. If a step fails, the partial disk is removed and the log is
left in `NEW-DISK.log`; each patch's page covers its own problems.

## Running A/UX

The disk boots Mac OS 7.1, then A/UX Startup launches A/UX, logged in as `root` with no
password. CommandShell, in the Apple menu, is the shell. Shut down with **Special → Shut
Down**: a power cut can damage the A/UX file system.

## For developers

Each patch folder holds its source (`src/`), what's built from it (`bin/`) and its scripts.
See [docs/development.md](docs/development.md).

## License

MIT; see [LICENSE](LICENSE).

## Disclaimer

This project is provided "as is", without warranty of any kind, express or implied,
including the warranties of merchantability and fitness for a particular purpose. A patched
operating system can lose data or leave a Mac unable to start; you use it at your own risk,
so keep backups. The authors are not liable for any damage or
loss arising from its use.

This project isn't affiliated with or endorsed by Apple. A/UX, Macintosh, Performa and
Quadra are trademarks of Apple Inc.; other names are trademarks of their owners.
