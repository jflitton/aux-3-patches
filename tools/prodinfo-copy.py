#!/usr/bin/env python3
"""Build a relocated copy of a ROM ProductInfo record with a fixed-up VideoInfo.

  prodinfo-copy.py ROM ROM_PRODUCTINFO_ADDR DEST_VADDR OUT.bin

The 605's VideoInfo gives VRAMLogAddr32 = 0x51900000 (the 605 ROM's MMU maps VRAM there);
A/UX does not map that, so the copy's VideoInfo says 0xF9000000 (the physical address,
which A/UX reaches through its supervisor transparent translation). Layout of OUT:
ProductInfo (0x48 bytes, self-relative offsets relocated to DEST_VADDR) at +0x00,
VideoInfo copy (0x20 bytes) at +0x60.
"""
import struct, sys

PI_SIZE = 0x48
OFFSET_FIELDS = (0x00, 0x04, 0x08, 0x0c, 0x28, 0x2c, 0x30, 0x34, 0x38)  # 0 = absent
VIDEO_AT, VIDEO_SIZE = 0x60, 0x20


def main():
    rom = open(sys.argv[1], 'rb').read()
    pi_addr, dest = int(sys.argv[2], 16), int(sys.argv[3], 16)
    base = 0x40800000
    pi = bytearray(rom[pi_addr - base:][:PI_SIZE])
    video_rom = pi_addr + struct.unpack_from('>i', pi, 0x08)[0]
    for off in OFFSET_FIELDS:
        v = struct.unpack_from('>i', pi, off)[0]
        if v:
            struct.pack_into('>i', pi, off, (v + pi_addr - dest) & 0xffffffff
                             if v + pi_addr - dest >= 0 else v + pi_addr - dest)
    video = bytearray(rom[video_rom - base:][:VIDEO_SIZE])
    struct.pack_into('>I', video, 4, struct.unpack_from('>I', video, 0)[0])  # log32 = phys
    struct.pack_into('>i', pi, 0x08, VIDEO_AT)
    out = pi + bytes(VIDEO_AT - PI_SIZE) + video
    open(sys.argv[4], 'wb').write(out)
    print('VideoInfo from rom %08x, copy:' % video_rom, video.hex(' ', 4))


if __name__ == '__main__':
    main()
