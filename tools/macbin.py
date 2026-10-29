#!/usr/bin/env python3
"""Wrap a macOS file (data fork + resource fork + FinderInfo) as MacBinary II.

  macbin.py SRC OUT.bin [MACNAME]

Reads the resource fork from SRC/..namedfork/rsrc and type/creator/flags from the
com.apple.FinderInfo xattr, so `hcopy -m OUT.bin :Folder:` recreates the file on HFS.
"""
import os, struct, subprocess, sys, time

MAC_EPOCH = 2082844800  # 1904-01-01 relative to 1970-01-01


def crc16_xmodem(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1
            crc &= 0xffff
    return crc


def finder_info(path):
    out = subprocess.run(['xattr', '-px', 'com.apple.FinderInfo', path],
                         capture_output=True, text=True, check=True).stdout
    return bytes.fromhex(out.replace(' ', '').replace('\n', ''))


def main():
    src, dst = sys.argv[1], sys.argv[2]
    name = (sys.argv[3] if len(sys.argv) > 3 else os.path.basename(src)).encode('mac_roman')
    data = open(src, 'rb').read()
    rsrc = open(os.path.join(src, '..namedfork', 'rsrc'), 'rb').read()
    fi = finder_info(src)
    mtime = int(os.stat(src).st_mtime) + MAC_EPOCH
    hdr = bytearray(128)
    hdr[1] = len(name)
    hdr[2:2 + len(name)] = name
    hdr[65:73] = fi[0:8]            # type, creator
    hdr[73] = fi[8] & ~0x01         # Finder flags high byte, clear "on desk"
    hdr[83:91] = struct.pack('>II', len(data), len(rsrc))
    hdr[91:99] = struct.pack('>II', mtime, mtime)
    hdr[101] = fi[9]                # Finder flags low byte
    hdr[122] = hdr[123] = 129       # MacBinary II
    hdr[124:126] = struct.pack('>H', crc16_xmodem(hdr[:124]))
    pad = lambda b: b + b'\0' * (-len(b) % 128)
    with open(dst, 'wb') as f:
        f.write(bytes(hdr) + pad(data) + pad(rsrc))


if __name__ == '__main__':
    main()
