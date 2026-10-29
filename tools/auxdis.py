#!/usr/bin/env python3
"""Symbol-annotated 68040 disassembly of an A/UX COFF image (run with .venv python).

  dis.py FILE SYMBOL [SYMBOL...]     disassemble each function up to the next symbol
  dis.py FILE 0xSTART 0xEND          disassemble an address range
  dis.py FILE xref 0xADDR|SYMBOL     find instructions whose operands mention ADDR
"""
import bisect, os, struct, sys

import capstone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from coff import Coff  # noqa: E402


class Image:
    def __init__(self, path):
        self.c = Coff(open(path, 'rb').read())
        self.secs = [s for s in self.c.sections if s['scnptr'] and s['size']]
        syms = [s for s in self.c.symbols if s['scnum'] > 0 and s['sclass'] in (2, 3, 6)
                and not s['name'].startswith('.')]
        self.by_name = {}
        for s in syms:
            self.by_name.setdefault(s['name'], s['value'] & 0xffffffff)
        self.by_addr = {}
        for s in syms:
            self.by_addr.setdefault(s['value'] & 0xffffffff, s['name'])
        self.addrs = sorted(self.by_addr)
        self.md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_BIG_ENDIAN |
                              capstone.CS_MODE_M68K_040)
        self.md.skipdata = True  # keep going past data/undecodable words

    def bytes_at(self, start, end):
        for s in self.secs:
            if s['vaddr'] <= start < s['vaddr'] + s['size']:
                off = s['scnptr'] + start - s['vaddr']
                return self.c.data[off:off + min(end, s['vaddr'] + s['size']) - start]
        raise ValueError('address %#x not in a loaded section' % start)

    def resolve(self, tok):
        return int(tok, 16) if tok.startswith('0x') else self.by_name[tok]

    def label(self, addr):
        i = bisect.bisect_right(self.addrs, addr) - 1
        if i < 0:
            return None
        base = self.addrs[i]
        if addr - base > 0x4000:
            return None
        return self.by_addr[base] + ('+%#x' % (addr - base) if addr != base else '')

    def annotate(self, op_str):
        notes = []
        for tok in op_str.replace('(', ' ').replace(')', ' ').replace(',', ' ').split():
            tok = tok.lstrip('#').rstrip('.wl')
            if tok.startswith('$') and len(tok) > 3:
                v = int(tok[1:], 16)
                name = self.label(v)
                if name:
                    notes.append(name)
        return ('  ; ' + ', '.join(notes)) if notes else ''

    def dis(self, start, end):
        code = self.bytes_at(start, end)
        for ins in self.md.disasm(code, start):
            if ins.address in self.by_addr:
                print('\n%s:' % self.by_addr[ins.address])
            print('  %08x  %-20s %-8s %s%s' % (ins.address, ins.bytes.hex(), ins.mnemonic,
                                              ins.op_str, self.annotate(ins.op_str)))

    def next_sym(self, addr):
        i = bisect.bisect_right(self.addrs, addr)
        return self.addrs[i] if i < len(self.addrs) else addr + 0x100

    def xref(self, target):
        pat = ('$%x' % target).lower()
        for s in self.secs:
            if not (s['flags'] & 0x20 or s['name'] == 'pstart'):
                continue
            code = self.c.data[s['scnptr']:s['scnptr'] + s['size']]
            for ins in self.md.disasm_lite(code, s['vaddr']):
                if pat in ins[3].lower():
                    print('  %08x %-28s %s %s' % (ins[0], self.label(ins[0]), ins[2], ins[3]))


def main():
    img = Image(sys.argv[1])
    args = sys.argv[2:]
    if args[0] == 'xref':
        img.xref(img.resolve(args[1]))
    elif len(args) == 2 and all(a.startswith('0x') for a in args):
        img.dis(int(args[0], 16), int(args[1], 16))
    else:
        for name in args:
            a = img.resolve(name)
            img.dis(a, img.next_sym(a))


if __name__ == '__main__':
    main()
