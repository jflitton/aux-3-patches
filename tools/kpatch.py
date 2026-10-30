#!/usr/bin/env python3
"""Helpers for the kernel patch generators (patches/*/kernel-patch.py): find patch sites
in an A/UX kernel (/unix or /etc/config.d/newunix) by symbol and instruction pattern, and
write them out as a tools/binpatch.py spec.

Kernel .text is loaded physically at the first 4KB page after pstart (endpstart rounded
up); pstart is identity-mapped. Hooks that run with the MMU off are entered at physical
addresses.
"""
import os, struct, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from binpatch import checksum  # noqa: E402
from coff import Coff  # noqa: E402

JMP, JSR, NOP, CLR_SP = b'\x4e\xf9', b'\x4e\xb9', b'\x4e\x71', b'\x42\xa7'


class Kernel:
    def __init__(self, path):
        self.c = Coff(open(path, 'rb').read())
        self.sym = {}
        for s in self.c.symbols:
            if s['scnum'] > 0:
                self.sym.setdefault(s['name'], s['value'] & 0xffffffff)
        self.text = [s for s in self.c.sections if s['name'] == '.text'][0]
        self.tphys = (self.sym['endpstart'] + 0xfff) & ~0xfff

    def section(self, va):
        for s in self.c.sections:
            if s['scnptr'] and s['vaddr'] <= va < s['vaddr'] + s['size']:
                return s
        raise SystemExit('%#x is not in a loaded section' % va)

    def read(self, va, n):
        s = self.section(va)
        return self.c.data[s['scnptr'] + va - s['vaddr']:][:n]

    def find(self, sec_name, pattern):
        """Unique address of pattern in a section."""
        s = [s for s in self.c.sections if s['name'] == sec_name][0]
        data = self.c.data[s['scnptr']:s['scnptr'] + s['size']]
        hits, i = [], data.find(pattern)
        while i >= 0:
            hits.append(s['vaddr'] + i)
            i = data.find(pattern, i + 2)
        if len(hits) != 1:
            raise SystemExit('pattern %s: %d matches in %s' % (pattern.hex(), len(hits), sec_name))
        return hits[0]

    def find_call(self, sec_name, target):
        """Unique 'jsr target' (absolute) in a section."""
        return self.find(sec_name, JSR + struct.pack('>I', self.sym[target]))

    def phys(self, va):
        return self.tphys + va - self.text['vaddr']

    def entry(self, va):
        """Address to reach va with the MMU off: .text is elsewhere physically, pstart
        is identity-mapped."""
        t = self.text['vaddr']
        return self.phys(va) if t <= va < t + self.text['size'] else va

    def label(self, va):
        """symbol+offset for va, using the nearest preceding uniquely named symbol."""
        names = {}
        for s in self.c.symbols:
            if s['scnum'] > 0 and s['sclass'] in (2, 3) and not s['name'].startswith('.'):
                names.setdefault(s['name'], set()).add(s['value'] & 0xffffffff)
        best = None
        for n, vals in names.items():
            v = next(iter(vals))
            if len(vals) == 1 and v <= va and (best is None or v > best[1]):
                best = (n, v)
        return best[0] if best[1] == va else '%s+%#x' % (best[0], va - best[1])

    def boardinit_switch(self):
        """boardinit's 'move.w machineID,d0; ext.l d0; bra.w switch': (site, switch)."""
        pat = b'\x30\x39' + struct.pack('>I', self.sym['machineID']) + b'\x48\xc0\x60\x00'
        start = self.sym['boardinit']
        i = self.read(start, 0x40).find(pat)
        if i < 0:
            raise SystemExit('no machineID switch at the start of boardinit')
        site = start + i
        disp = struct.unpack('>h', self.read(site + 10, 2))[0]
        return site, site + 10 + disp

    def table_entry(self, table, target):
        """Address of the entry in a null-terminated function table that points at target."""
        a = self.sym[table]
        while True:
            v = struct.unpack('>I', self.read(a, 4))[0]
            if v == self.sym[target]:
                return a
            if v == 0:
                raise SystemExit('%s has no %s entry' % (table, target))
            a += 4

    def memsize_rbv(self):
        """memsize's choice between the RBV banks and one bank, and the one-bank banksize
        call after it: (address of 'tst.l rbv_exists; bne.w', address of its
        'moveq #0,d0; move.l d0,-(sp); jsr banksize(pc)')."""
        tst = b'\x4a\xb9' + struct.pack('>I', self.sym['rbv_exists']) + b'\x66\x00'
        call = (b'\x2e\xbc' + struct.pack('>I', self.sym['rambanks']) +
                b'\x2f\x02\x70\x00\x2f\x00\x4e\xba')
        start = self.sym['memsize']
        code = self.read(start, 0x200)
        hits = [j for j in range(len(code)) if code.startswith(tst, j)
                and code.startswith(call, j + 10)]
        if len(hits) != 1:
            raise SystemExit('memsize: %d banksize calls after rbv_exists' % len(hits))
        site = start + hits[0] + 10 + 8
        disp = struct.unpack('>h', self.read(site + 6, 2))[0]
        if site + 6 + disp != self.sym['banksize']:
            raise SystemExit('memsize: the call at %#x is not to banksize' % (site + 4))
        return start + hits[0], site

    def memsize_banksize(self):
        """memsize's banksize call on the path after 'tst.l rbv_exists; bne.w':
        address of its 'moveq #0,d0; move.l d0,-(sp); jsr banksize(pc)'."""
        return self.memsize_rbv()[1]


def elf_symbols(elf):
    nm = subprocess.run(['m68k-elf-nm', elf], capture_output=True, text=True, check=True).stdout
    return {l.split()[2]: int(l.split()[0], 16) for l in nm.splitlines() if len(l.split()) == 3}


def emit(k, sites):
    """Print sites, (address, new bytes, comment), as binpatch.py 'at' entries."""
    for va, new, what in sites:
        print()
        print('at %s  ; %#x: %s' % (k.label(va), va, what))
        print('check %s' % checksum(k.read(va, len(new))))
        for i in range(0, len(new), 32):
            print('new ' + new[i:i + 32].hex(' ', 2))
