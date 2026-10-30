#!/usr/bin/env python3
"""Wrap a Mac file, as `unar -k visible` extracts it, as MacBinary II.

  macbin.py SRC.rsrc OUT.bin [MACNAME]

SRC.rsrc is the AppleDouble file unar writes beside the data fork (SRC, missing if the data
fork is empty): it holds the resource fork and the Finder info (type, creator, flags). The
same on macOS and Linux, so `hcopy -m OUT.bin :Folder:` recreates the file on HFS.
"""
import os, struct, sys

MAC_EPOCH = 2082844800  # 1904-01-01 relative to 1970-01-01
APPLEDOUBLE = 0x00051607
RSRC, FINDER_INFO = 2, 9  # AppleDouble entry IDs


def crc16_xmodem(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1
            crc &= 0xffff
    return crc


def appledouble(path):
    """The entries of an AppleDouble file, by ID."""
    ad = open(path, 'rb').read()
    magic, n = struct.unpack('>I20xH', ad[:26])
    if magic != APPLEDOUBLE:
        sys.exit(f'{path} is not an AppleDouble file')
    entries = {}
    for i in range(n):
        eid, off, length = struct.unpack('>III', ad[26 + 12 * i:38 + 12 * i])
        entries[eid] = ad[off:off + length]
    return entries


def main():
    src, dst = sys.argv[1], sys.argv[2]
    base = src[:-len('.rsrc')] if src.endswith('.rsrc') else src
    name = (sys.argv[3] if len(sys.argv) > 3 else os.path.basename(base)).encode('mac_roman')
    ad = appledouble(src)
    data = open(base, 'rb').read() if base != src and os.path.exists(base) else b''
    rsrc = ad.get(RSRC, b'')
    fi = ad.get(FINDER_INFO, b'').ljust(10, b'\0')
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
