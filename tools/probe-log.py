#!/usr/bin/env python3
"""Render a tools/mame-605-probe.lua log: join putchar bytes into text, resolve panic strings.

  probe-log.py KERNEL_COFF LOG
"""
import bisect, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from coff import Coff  # noqa: E402


def main():
    c = Coff(open(sys.argv[1], 'rb').read())
    syms = sorted({(s['value'] & 0xffffffff, s['name']) for s in c.symbols
                   if s['scnum'] > 0 and s['sclass'] in (2, 3) and not s['name'].startswith('.')})
    addrs = [a for a, _ in syms]

    def sym(a):
        i = bisect.bisect_right(addrs, a) - 1
        return '%s+%#x' % (syms[i][1], a - addrs[i]) if i >= 0 and a - addrs[i] < 0x4000 else hex(a)

    def cstr(a):
        for s in c.sections:
            if s['scnptr'] and s['vaddr'] <= a < s['vaddr'] + s['size']:
                off = s['scnptr'] + a - s['vaddr']
                return c.data[off:c.data.index(b'\0', off)].decode('latin-1')
        return '?'

    text = []
    for line in open(sys.argv[2]):
        line = line.rstrip('\n')
        if line.startswith('P '):
            text.append(chr(int(line[2:], 16)))
            continue
        if text:
            print('CONSOLE| ' + ''.join(text).replace('\n', '\nCONSOLE| '))
            text = []
        m = re.match(r'X (exec|exit\(\w+\)) ([0-9a-f]+)(?: \| ([0-9a-f]+))?', line)
        if m:
            dec = lambda h: bytes.fromhex(h).split(b'\0')[0].decode('latin-1')
            print('%-10s %-14s %s' % (m.group(1), dec(m.group(2)), dec(m.group(3)) if m.group(3) else ''))
            continue
        m = re.match(r'PANIC fmt=(\w+) args (\w+) (\w+) ret (.*)', line)
        if m:
            print('PANIC "%s" args %s %s' % (cstr(int(m.group(1), 16)), m.group(2), m.group(3)))
            print('   called from: ' + ' <- '.join(sym(int(x, 16)) for x in m.group(4).split()))
            continue
        print(line)
    if text:
        print('CONSOLE| ' + ''.join(text).replace('\n', '\nCONSOLE| '))


if __name__ == '__main__':
    main()
