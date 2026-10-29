#!/usr/bin/env python3
"""A/UX m68k COFF (magic 0x0150) reader.

  coff.py FILE hdr             file/optional header and section table
  coff.py FILE syms            symbol table: value section class name
  coff.py FILE ar              list members of an ar(1) archive (boot.d modules)
  coff.py FILE ar MEMBER syms  symbols of one archive member
  coff.py FILE relocs          relocation entries with the symbol each one refers to
"""
import struct, sys

SCLASS = {2: 'ext', 3: 'static', 6: 'label', 101: 'func', 103: 'file', 107: 'eos',
          10: 'strtag', 8: 'mos', 13: 'typdef', 4: 'reg', 1: 'auto', 9: 'arg', 0: 'null'}

# The only relocation type A/UX's own modules use (boot.d, 3.0.1 and 3.1): a 32-bit field
# to which the linker adds (final address - value in this object) of the symbol. For a
# section symbol that value is the section's vaddr, for an undefined one 0, and for a
# common one its size, so the field holds the target's address as the object lays it out.
R_RELLONG = 17


class Coff:
    def __init__(self, data):
        self.data = data
        (self.magic, self.nscns, self.timdat, self.symptr, self.nsyms, self.opthdr,
         self.flags) = struct.unpack('>HHiiiHH', data[:20])
        if self.magic != 0x0150:
            raise ValueError('not m68k COFF (magic %#x)' % self.magic)
        self.aout = None
        if self.opthdr >= 28:
            self.aout = dict(zip(('magic', 'vstamp', 'tsize', 'dsize', 'bsize', 'entry',
                                  'text_start', 'data_start'),
                                 struct.unpack('>hhiiiiii', data[20:48])))
        self.sections = []
        off = 20 + self.opthdr
        for i in range(self.nscns):
            s = data[off + 40 * i: off + 40 * (i + 1)]
            name = s[:8].split(b'\0')[0].decode('latin-1')
            paddr, vaddr, size, scnptr, relptr, lnnoptr, nreloc, nlnno, flags = \
                struct.unpack('>iiiiiiHHi', s[8:40])
            self.sections.append(dict(name=name, paddr=paddr, vaddr=vaddr, size=size,
                                      scnptr=scnptr, relptr=relptr, nreloc=nreloc,
                                      flags=flags))
        strtab = self.symptr + 18 * self.nsyms
        self.strtab = data[strtab:] if self.symptr else b''
        self.symbols = list(self._syms())

    def _name(self, raw):
        if raw[:4] == b'\0\0\0\0':
            off = struct.unpack('>i', raw[4:8])[0]
            return self.strtab[off:self.strtab.index(b'\0', off)].decode('latin-1')
        return raw.split(b'\0')[0].decode('latin-1')

    def _syms(self):
        i = 0
        while i < self.nsyms:
            e = self.data[self.symptr + 18 * i: self.symptr + 18 * (i + 1)]
            value, scnum, typ, sclass, numaux = struct.unpack('>ihHBB', e[8:18])
            yield dict(name=self._name(e[:8]), value=value, scnum=scnum, type=typ,
                       sclass=sclass, numaux=numaux, index=i)
            i += 1 + numaux

    def section_bytes(self, name):
        s = [s for s in self.sections if s['name'] == name][0]
        return s, self.data[s['scnptr']:s['scnptr'] + s['size']]

    def relocs(self, sec):
        """(vaddr, symbol index, type) of each relocation entry of section dict SEC."""
        for r in range(sec['nreloc']):
            yield struct.unpack('>iiH', self.data[sec['relptr'] + 10 * r:
                                                   sec['relptr'] + 10 * (r + 1)])

    def link(self, bases, address):
        """Lay the object out as the A/UX linker would: each section NAME at bases[NAME],
        each undefined or common symbol at address(name). Returns {NAME: bytes} for the
        sections with contents."""
        syms = {s['index']: s for s in self.symbols}
        out = {}
        for sec in self.sections:
            if not sec['scnptr'] or sec['name'] not in bases:
                continue
            buf = bytearray(self.data[sec['scnptr']:sec['scnptr'] + sec['size']])
            for vaddr, symndx, typ in self.relocs(sec):
                if typ != R_RELLONG:
                    raise ValueError('relocation type %d at %s+%#x' % (typ, sec['name'], vaddr))
                s = syms[symndx]
                if s['scnum'] > 0:
                    target = self.sections[s['scnum'] - 1]
                    new = bases[target['name']] + s['value'] - target['vaddr']
                else:
                    new = address(s['name'])
                off = vaddr - sec['vaddr']
                field = struct.unpack_from('>I', buf, off)[0]
                struct.pack_into('>I', buf, off, (field + new - s['value']) & 0xffffffff)
            out[sec['name']] = bytes(buf)
        return out


def ar_members(data):
    if data[:8] != b'!<arch>\n':
        raise ValueError('not an ar archive')
    off, out = 8, []
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        name = hdr[:16].decode('latin-1').strip().rstrip('/')
        size = int(hdr[48:58].decode().strip())
        out.append((name, data[off + 60:off + 60 + size]))
        off += 60 + size + (size & 1)
    return out


def print_syms(c):
    secname = {i + 1: s['name'] for i, s in enumerate(c.sections)}
    secname.update({0: 'UNDEF', -1: 'ABS', -2: 'DEBUG'})
    for s in c.symbols:
        print('%08x %-6s %-7s %s' % (s['value'] & 0xffffffff, secname.get(s['scnum'], s['scnum']),
                                    SCLASS.get(s['sclass'], s['sclass']), s['name']))


def main():
    data = open(sys.argv[1], 'rb').read()
    cmd = sys.argv[2]
    if cmd == 'ar':
        members = ar_members(data)
        if len(sys.argv) == 3:
            for name, d in members:
                print('%-16s %8d' % (name, len(d)))
            return
        data = dict(members)[sys.argv[3]]
        cmd = sys.argv[4]
    c = Coff(data)
    if cmd == 'hdr':
        print('magic=%#x nscns=%d nsyms=%d flags=%#x aout=%s' % (c.magic, c.nscns, c.nsyms,
              c.flags, c.aout))
        for s in c.sections:
            print('  %-8s vaddr=%08x size=%08x scnptr=%08x nreloc=%d flags=%#x' % (
                s['name'], s['vaddr'], s['size'], s['scnptr'], s['nreloc'], s['flags']))
    elif cmd == 'syms':
        print_syms(c)
    elif cmd == 'relocs':
        syms = {s['index']: s for s in c.symbols}
        for sec in c.sections:
            for vaddr, symndx, typ in c.relocs(sec):
                print('%-8s %08x type %2d %s' % (sec['name'], vaddr, typ, syms[symndx]['name']))


if __name__ == '__main__':
    main()
