#!/usr/bin/env python3
"""Emit a GNU ld script defining kernel symbols, so patch code can link against a kernel.

  ksyms-ld.py KERNEL_COFF > kernel.ld

Static symbols are included (the Egret helpers are static); the first definition of a
name wins, matching how tools/auxdis.py resolves names.
"""
import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from coff import Coff  # noqa: E402


def main():
    c = Coff(open(sys.argv[1], 'rb').read())
    seen = set()
    for s in c.symbols:
        n = s['name']
        if s['scnum'] == 0 or s['sclass'] not in (2, 3) or n in seen:
            continue
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', n):
            continue
        seen.add(n)
        print('%s = 0x%08x;' % (n, s['value'] & 0xffffffff))


if __name__ == '__main__':
    main()
