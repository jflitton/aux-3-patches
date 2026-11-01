#!/usr/bin/env python3
"""Which Macs a System Enabler is for: its number and the BoxFlags in its 'gbly' resource.

  enabler.py SRC.rsrc

SRC.rsrc is the AppleDouble file `unar -k visible` writes for the enabler (whose data fork
is empty), as for tools/macbin.py. Prints the enabler's number, from its file name
("System Enabler 065 1.2.sea", "System Enabler 003 (1.1)", "System Enabler 403"; - if
the name has none), then the BoxFlags it lists, in hex: "065 53 54 58 59 56". A Mac's
BoxFlag is its Gestalt machine type - 6; System 7.1 loads the enabler that lists it.

'gbly' (one, ID -16385): a version word (1), a long, a count word, then each BoxFlag as a
word. Enabler 065 1.2 lists 0x53 0x54 0x58 0x59 0x56, 003 1.1 lists 0x15 0x38, 403 1.0.2
lists 0x4b 0x32 0x4d 0x4a.
"""
import os, re, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from macbin import RSRC, appledouble  # noqa: E402


def resources(fork, rtype):
    """The data of every resource of type rtype in a resource fork."""
    data_off, map_off = struct.unpack('>II', fork[:8])
    types = map_off + struct.unpack('>H', fork[map_off + 24:map_off + 26])[0]
    out = []
    for i in range(struct.unpack('>H', fork[types:types + 2])[0] + 1):
        t, n, refs = struct.unpack('>4sHH', fork[types + 2 + 8 * i:types + 10 + 8 * i])
        if t != rtype:
            continue
        for j in range(n + 1):
            ref = types + refs + 12 * j
            off = data_off + (struct.unpack('>I', fork[ref + 4:ref + 8])[0] & 0xffffff)
            length = struct.unpack('>I', fork[off:off + 4])[0]
            out.append(fork[off + 4:off + 4 + length])
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().split('\n\n')[1])
    path = sys.argv[1]
    fork = appledouble(path).get(RSRC, b'')
    if len(fork) < 16:
        sys.exit(f'{path} has no resource fork')
    gbly = resources(fork, b'gbly')
    if len(gbly) != 1 or len(gbly[0]) < 8:
        sys.exit(f'{path} is not a System Enabler: no gbly resource')
    g = gbly[0]
    version, count = struct.unpack('>H4xH', g[:8])
    if version != 1 or len(g) != 8 + 2 * count:
        sys.exit(f'{path}: gbly version {version}, {len(g)} bytes for {count} BoxFlags')
    flags = struct.unpack('>%dH' % count, g[8:])
    m = re.search(r'System Enabler (\d{3})', os.path.basename(path))
    print(' '.join([m.group(1) if m else '-'] + ['%02x' % f for f in flags]))


if __name__ == '__main__':
    main()
