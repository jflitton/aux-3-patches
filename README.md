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

## What you need

- A Mac running macOS, with 3 GB free.
- An A/UX 3.1 disk image. Tested with `AUX_3_1_1GB_Use_In_Shoebill.zip`, widely archived
  online; give the script the zip or the `.dsk` inside it.
- Whatever your chosen patches need (see their pages).

## Make the disk

1. Install [Homebrew](https://brew.sh) by pasting the command from its home page into
   Terminal (Applications → Utilities). For MEMCjr or Sonora, also run
   `brew install hfsutils unar`.
2. Download this project (on GitHub: **Code → Download ZIP**) and unzip it.
3. In Terminal, type `cd `, drag the project folder onto the window and press Return. Then
   run `make-disk.sh` with the A/UX image, a name for the new disk, and your patches:

       ./make-disk.sh ~/Downloads/AUX_3_1_1GB_Use_In_Shoebill.zip ~/Desktop/HD0_AUX.hda \
           --memcjr ~/Downloads/System_Enabler_065_12-sea.bin --daynaport --date \
           --ip 192.168.1.50

   For an LC III, use `--sonora ~/Downloads/System_Enabler_003_1.1.sea.bin` in place of
   `--memcjr …`. `./make-disk.sh --help` lists every option.

## Start A/UX

Mac OS 7.1 starts, then A/UX Startup launches A/UX, logged in as `root` with no password.
**CommandShell**, in the Apple menu, gives you a Unix command line. If the Mac starts from
another disk, choose the A/UX disk in the Startup Disk control panel.

Always use **Special → Shut Down** before switching off: cutting the power can damage the
A/UX disk.

## Troubleshooting

- **"Permission denied":** run `sh make-disk.sh …` instead.
- **Tools missing:** install them as the script says, then open a new Terminal window.
- **"Isn't an A/UX 3.1 disk":** these patches are for A/UX 3.1 only.
- **Anything else:** the script names the step that failed and saves a log next to the new
  disk's name.

Problems with a particular patch are on its page.

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
