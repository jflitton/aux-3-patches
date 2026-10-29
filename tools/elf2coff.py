#!/usr/bin/env python3
"""Turn an m68k ELF relocatable object into an A/UX COFF module for /etc/boot.d.

  elf2coff.py IN.o OUT                   convert
  elf2coff.py verify IN.o OUT            link both at the same addresses (ELF with
                                         m68k-elf-ld, COFF with coff.Coff.link) and
                                         compare the bytes
  elf2coff.py undef OUT KERNEL           list OUT's undefined symbols that KERNEL lacks
                                         (exit 1 if there are any)

IN must have exactly the sections .text, .data and .bss, as `m68k-elf-ld -r` makes them
with patches/daynaport/src/module.ld. The output is laid out as A/UX's own assembler does it: .text
at 0, .data at 0x400000, .bss right after .data. Every relocation becomes the one type
A/UX's modules use (coff.R_RELLONG); PC-relative references must stay inside their own
section and are resolved here.
"""
import os, struct, subprocess, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from coff import Coff, R_RELLONG

DATA_VADDR = 0x400000
R_68K_32, R_68K_PC32, R_68K_PC16, R_68K_PC8 = 1, 4, 5, 6
SHN_UNDEF, SHN_ABS, SHN_COMMON = 0, 0xfff1, 0xfff2
STB_LOCAL, STT_SECTION, STT_FILE = 0, 3, 4
C_EXT, C_STAT, C_FILE = 2, 3, 103


class Elf:
    def __init__(self, data):
        if data[:4] != b'\x7fELF' or data[4] != 1 or data[5] != 2:
            raise ValueError('not a big-endian ELF32 file')
        e_shoff, = struct.unpack('>I', data[32:36])
        e_shentsize, e_shnum, e_shstrndx = struct.unpack('>HHH', data[46:52])
        self.data = data
        self.sections = []
        for i in range(e_shnum):
            h = struct.unpack('>10I', data[e_shoff + i * e_shentsize:][:40])
            self.sections.append(dict(zip(('name', 'type', 'flags', 'addr', 'offset', 'size',
                                           'link', 'info', 'addralign', 'entsize'), h)))
        names = self.sections[e_shstrndx]
        for s in self.sections:
            s['name'] = self._str(names, s['name'])
        self.by_name = {s['name']: i for i, s in enumerate(self.sections)}
        symtab = [s for s in self.sections if s['type'] == 2]  # SHT_SYMTAB
        self.symbols = []
        if symtab:
            st = symtab[0]
            strtab = self.sections[st['link']]
            for o in range(st['offset'], st['offset'] + st['size'], 16):
                name, value, size, info, other, shndx = struct.unpack('>IIIBBH', data[o:o + 16])
                self.symbols.append(dict(name=self._str(strtab, name), value=value, size=size,
                                         bind=info >> 4, type=info & 15, shndx=shndx))

    def _str(self, sec, off):
        o = sec['offset'] + off
        return self.data[o:self.data.index(b'\0', o)].decode('latin-1')

    def contents(self, name):
        s = self.sections[self.by_name[name]]
        if s['type'] == 8:  # SHT_NOBITS
            return bytes(s['size'])
        return self.data[s['offset']:s['offset'] + s['size']]

    def relas(self, name):
        """(offset, symbol index, type, addend) for section NAME."""
        i = self.by_name[name]
        for s in self.sections:
            if s['type'] == 4 and s['info'] == i:  # SHT_RELA
                for o in range(s['offset'], s['offset'] + s['size'], 12):
                    off, info, addend = struct.unpack('>IIi', self.data[o:o + 12])
                    yield off, info >> 8, info & 0xff, addend
            elif s['type'] == 9 and s['info'] == i:  # SHT_REL
                raise ValueError('REL relocations are not supported')


def convert(elf):
    allowed = {'', '.text', '.data', '.bss', '.rela.text', '.rela.data', '.symtab', '.strtab',
               '.shstrtab'}
    extra = [s['name'] for s in elf.sections if s['name'] not in allowed and s['flags'] & 2]
    if extra:
        raise ValueError('unexpected allocated sections %s (link with module.ld)' % extra)
    # sizes padded to 4 bytes, as in A/UX's own objects
    text = bytearray(elf.contents('.text'))
    text += bytes(-len(text) % 4)
    data = bytearray(elf.contents('.data'))
    data += bytes(-len(data) % 4)
    bsize = len(elf.contents('.bss'))
    bsize += -bsize % 4
    base = {'.text': 0, '.data': DATA_VADDR, '.bss': DATA_VADDR + len(data)}
    secidx = {elf.by_name[n]: n for n in base}
    buf = {'.text': text, '.data': data}

    # Symbol table: .file, the three section symbols, then functions and data with C_STAT
    # or C_EXT, then the undefined externals. Section symbols get COFF indices 2, 4, 6.
    coffsec = {'.text': 1, '.data': 2, '.bss': 3}
    secsym = {'.text': 2, '.data': 4, '.bss': 6}
    local, glob, undef = [], [], []
    for i, s in enumerate(elf.symbols):
        if s['type'] in (STT_SECTION, STT_FILE) or not s['name']:
            continue
        if s['shndx'] == SHN_COMMON:
            raise ValueError('common symbol %s (build with -fno-common)' % s['name'])
        if s['shndx'] == SHN_UNDEF:
            undef.append(i)
        elif s['shndx'] in secidx:
            (local if s['bind'] == STB_LOCAL else glob).append(i)
        elif s['shndx'] != SHN_ABS:
            raise ValueError('symbol %s in section %d' % (s['name'], s['shndx']))
    coffidx = {}
    n = 8
    for i in local + glob + undef:
        coffidx[i] = n
        n += 1

    relocs = {'.text': [], '.data': []}
    for sec in relocs:
        for off, symi, typ, addend in elf.relas(sec):
            s = elf.symbols[symi]
            where = base[sec] + off
            if s['shndx'] in secidx:
                tsec = secidx[s['shndx']]
                target = base[tsec] + s['value'] + addend
                rsym = secsym[tsec]
            elif s['shndx'] == SHN_ABS:
                target, tsec, rsym = s['value'] + addend, None, None
            else:
                target, tsec, rsym = addend, None, coffidx[symi]
            if typ == R_68K_32:
                struct.pack_into('>I', buf[sec], off, target & 0xffffffff)
                if rsym is not None:
                    relocs[sec].append((where, rsym))
            elif typ in (R_68K_PC32, R_68K_PC16, R_68K_PC8):
                if tsec != sec:
                    raise ValueError('PC-relative %s+%#x to %s outside %s' % (
                        sec, off, s['name'] or tsec, sec))
                disp = target - where
                fmt, lim = {R_68K_PC32: ('>i', 1 << 31), R_68K_PC16: ('>h', 1 << 15),
                            R_68K_PC8: ('>b', 1 << 7)}[typ]
                if not -lim <= disp < lim:
                    raise ValueError('PC-relative %s+%#x out of range' % (sec, off))
                struct.pack_into(fmt, buf[sec], off, disp)
            else:
                raise ValueError('relocation type %d at %s+%#x' % (typ, sec, off))

    strtab = bytearray(b'\0\0\0\0')

    def name8(name):
        b = name.encode('latin-1')
        if len(b) <= 8:
            return b.ljust(8, b'\0')
        off = len(strtab)
        strtab.extend(b + b'\0')
        return b'\0\0\0\0' + struct.pack('>I', off)

    def ent(name, value, scnum, sclass, numaux=0):
        return name8(name) + struct.pack('>ihHBB', value, scnum, 0, sclass, numaux)

    first_ext = 8 + len(local)
    syms = bytearray(ent('.file', first_ext, -2, C_FILE, 1))
    syms += b'dayna.c'.ljust(18, b'\0')
    for name in ('.text', '.data', '.bss'):
        size = {'.text': len(text), '.data': len(data), '.bss': bsize}[name]
        syms += ent(name, base[name], coffsec[name], C_STAT, 1)
        syms += struct.pack('>iH', size, len(relocs.get(name, []))).ljust(18, b'\0')
    for i in local + glob:
        s = elf.symbols[i]
        sec = secidx[s['shndx']]
        syms += ent(s['name'], base[sec] + s['value'], coffsec[sec],
                    C_STAT if s['bind'] == STB_LOCAL else C_EXT)
    for i in undef:
        syms += ent(elf.symbols[i]['name'], 0, 0, C_EXT)
    struct.pack_into('>I', strtab, 0, len(strtab))

    nsyms = len(syms) // 18
    hdr = 20 + 28 + 3 * 40
    text_ptr = hdr
    data_ptr = text_ptr + len(text)
    trel_ptr = data_ptr + len(data)
    drel_ptr = trel_ptr + 10 * len(relocs['.text'])
    sym_ptr = drel_ptr + 10 * len(relocs['.data'])
    out = bytearray()
    out += struct.pack('>HHiiiHH', 0x0150, 3, 0, sym_ptr, nsyms, 28, 0x020c)
    out += struct.pack('>hhiiiiii', 0o410, 0, len(text), len(data), bsize, 0, 0, DATA_VADDR)

    def shdr(name, vaddr, size, ptr, relptr, nrel, flags):
        return name.encode().ljust(8, b'\0') + struct.pack(
            '>iiiiiiHHi', vaddr, vaddr, size, ptr, relptr if nrel else 0, 0, nrel, 0, flags)

    out += shdr('.text', 0, len(text), text_ptr, trel_ptr, len(relocs['.text']), 0x20)
    out += shdr('.data', DATA_VADDR, len(data), data_ptr if data else 0, drel_ptr,
                len(relocs['.data']), 0x40)
    out += shdr('.bss', base['.bss'], bsize, 0, 0, 0, 0x80)
    out += text + data
    for sec in ('.text', '.data'):
        for where, rsym in relocs[sec]:
            out += struct.pack('>iiH', where, rsym, R_RELLONG)
    out += syms + strtab
    return bytes(out)


def verify(elf_path, coff_path):
    """Link the ELF with GNU ld and the COFF with Coff.link at the same addresses."""
    elf = Elf(open(elf_path, 'rb').read())
    c = Coff(open(coff_path, 'rb').read())
    bases = {'.text': 0x10100000, '.data': 0x11100000, '.bss': 0x12100000}
    undef = sorted({s['name'] for s in elf.symbols if s['shndx'] == SHN_UNDEF and s['name']})
    addr = {n: 0x20000000 + 0x1000 * i for i, n in enumerate(undef)}
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'linked.elf')
        cmd = ['m68k-elf-ld', '-o', out, '-e', '0', '-Ttext=%#x' % bases['.text'],
               '-Tdata=%#x' % bases['.data'], '-Tbss=%#x' % bases['.bss'], elf_path]
        cmd += ['--defsym=%s=%#x' % (n, a) for n, a in addr.items()]
        subprocess.run(cmd, check=True)
        linked = Elf(open(out, 'rb').read())
        mine = c.link(bases, lambda n: addr[n])
        ok = True
        for name in ('.text', '.data'):
            a = linked.contents(name) if name in linked.by_name else b''
            b = mine.get(name, b'')
            b = b[:len(a)] if not any(b[len(a):]) else b      # padding must be zeros
            diff = [i for i in range(max(len(a), len(b))) if a[i:i + 1] != b[i:i + 1]]
            print('%s: %d bytes, %d differ%s' % (name, len(a), len(diff),
                                                  (' at %s' % [hex(d) for d in diff[:8]]) if diff else ''))
            ok &= not diff
    return ok


def main():
    if sys.argv[1] == 'verify':
        sys.exit(0 if verify(sys.argv[2], sys.argv[3]) else 1)
    if sys.argv[1] == 'undef':
        c = Coff(open(sys.argv[2], 'rb').read())
        k = Coff(open(sys.argv[3], 'rb').read())
        have = {s['name'] for s in k.symbols if s['sclass'] == C_EXT and s['scnum'] != 0}
        missing = sorted(s['name'] for s in c.symbols
                         if s['sclass'] == C_EXT and s['scnum'] == 0 and s['name'] not in have)
        for n in missing:
            print(n)
        sys.exit(1 if missing else 0)
    elf = Elf(open(sys.argv[1], 'rb').read())
    open(sys.argv[2], 'wb').write(convert(elf))


if __name__ == '__main__':
    main()
