#!/usr/bin/env python3
"""Link a boot.d module into a configured A/UX /unix, as autoconfig would.

  linkmod.py UNIX MODULE MASTER OUT     link MODULE (an /etc/boot.d object) into UNIX as
                                        its master.d file MASTER says; write OUT
  linkmod.py check UNIX MODULE MASTER   take MODULE, the last module linked into UNIX,
                                        out again and link it back: the result must be
                                        UNIX byte for byte

autoconfig makes /unix with ld: /etc/config.d/newunix (fully linked, no relocations) at
its own addresses, each module's .text, .data and .bss after the kernel's, and after the
last .bss the commons nothing defines. It then fills in the tables the modules' master.d
flags ask for and gives each a 256-byte record in the MODULES section. The modules'
local symbols (less their .data and .bss section symbols) follow the kernel's, ahead of
all the globals; their globals come last. So linking one more module onto the end of a
configured /unix makes the kernel autoconfig would with that module listed last, except
that its .bss follows the other modules' commons rather than preceding them (moving
those would mean relinking every module). The Mac then needs no relink. `check` shows
it on Apple's own /unix and its last module (ufs in 3.1), whose .bss it links back where
ld put it.

Only software modules: master.d flag 's', and 'p' with an init stage (f, s, n, 0 or l:
the prefix's init routine goes into init_first ... init_last). The module name (the
MODULES record) is MODULE's file name.
"""
import os, struct, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from coff import Coff

SECTIONS = ['pstart', '.text', '.data', '.bss', 'MODULES']
C_EXT, C_FILE = 2, 103
PAGE = 0x1000
RECORD = 0x100
STAGES = {'f': 'init_first', 's': 'init_second', 'n': 'init_normal', '0': 'init_0',
          'l': 'init_last'}
F_SOFTWARE = 0x80       # 's' in a MODULES record's flags (ufs, bnet, tty, streams)


def align(n, a):
    return (n + a - 1) & -a


def read_syms(c):
    """Symbol table entries of C as dicts, each with its aux entries' raw bytes."""
    out, i = [], 0
    while i < c.nsyms:
        e = c.data[c.symptr + 18 * i: c.symptr + 18 * (i + 1)]
        value, scnum, typ, sclass, numaux = struct.unpack('>ihHBB', e[8:18])
        aux = [c.data[c.symptr + 18 * (i + 1 + j): c.symptr + 18 * (i + 2 + j)]
               for j in range(numaux)]
        out.append(dict(name=c._name(e[:8]), value=value, scnum=scnum, type=typ,
                        sclass=sclass, aux=aux))
        i += 1 + numaux
    return out


def nentries(syms):
    return sum(1 + len(s['aux']) for s in syms)


def split_syms(syms):
    """(locals, globals): every local must come before the first global."""
    first = next((i for i, s in enumerate(syms) if s['sclass'] == C_EXT), len(syms))
    if any(s['sclass'] != C_EXT for s in syms[first:]):
        raise ValueError('local symbols after the globals')
    return syms[:first], syms[first:]


def kept_locals(syms):
    """A module's locals as autoconfig keeps them: all but the .data and .bss section
    symbols."""
    return [s for s in syms if not (s['name'] in ('.data', '.bss') and s['aux'])]


def chain_files(syms):
    """Set each .file's value to the index of the next .file, the last one's to that of
    the first global."""
    prev, i = None, 0
    for s in syms:
        if s['sclass'] in (C_FILE, C_EXT) and prev:
            prev['value'] = i
            prev = None
        if s['sclass'] == C_FILE:
            prev = s
        elif s['sclass'] == C_EXT:
            break
        i += 1 + len(s['aux'])


def master(path):
    """(flags, prefix, major, units) from a master.d file's module line."""
    for line in open(path):
        f = line.split()
        if len(f) == 6 and not f[0].startswith('*'):
            num = lambda v: -1 if v == '-' else int(v, 0)
            return f[0], f[2], num(f[3]), max(num(f[4]), 0)
    raise ValueError('%s: no module line' % path)


def parse_flags(flags):
    """(MODULES flag bits, init stage or None) for a software module's master flags."""
    bits, stage, i = 0, None, 0
    while i < len(flags):
        if flags[i] == 'p' and flags[i + 1:i + 2] in STAGES:
            stage = flags[i + 1]
            i += 2
            continue
        if flags[i] != 's':
            raise ValueError("master flag '%s': only software modules (s, p<stage>)"
                             % flags[i])
        bits |= F_SOFTWARE
        i += 1
    if not bits:
        raise ValueError("master flags '%s': not a software module" % flags)
    return bits, stage


class Kernel:
    """A configured /unix: its sections, symbols and the layout rules it follows."""

    def __init__(self, data):
        c = Coff(data)
        if [s['name'] for s in c.sections] != SECTIONS:
            raise ValueError('sections %s, expected %s' % ([s['name'] for s in c.sections],
                                                           SECTIONS))
        if any(s['nreloc'] for s in c.sections):
            raise ValueError('kernel has relocation entries')
        self.flags, self.timdat = c.flags, c.timdat
        self.aout = bytearray(data[20:20 + c.opthdr])
        self.sec = {s['name']: dict(s) for s in c.sections}
        self.body = {n: bytearray(c.section_bytes(n)[1]) for n in SECTIONS if n != '.bss'}
        self.syms = read_syms(c)
        self.check_layout()

    def sym(self, name):
        for s in self.syms:
            if s['name'] == name and s['sclass'] == C_EXT and s['scnum'] > 0:
                return s['value']
        raise KeyError(name)

    def where(self, addr, n):
        """(section body, offset) of N bytes at ADDR in pstart or .data."""
        for name in ('pstart', '.data'):
            s = self.sec[name]
            if s['vaddr'] <= addr and addr + n <= s['vaddr'] + s['size']:
                return self.body[name], addr - s['vaddr']
        raise ValueError('%#x not in pstart or .data' % addr)

    def get(self, addr, count=1):
        buf, off = self.where(addr, 4 * count)
        return list(struct.unpack_from('>%dI' % count, buf, off))

    def put(self, addr, *values):
        buf, off = self.where(addr, 4 * len(values))
        struct.pack_into('>%dI' % len(values), buf, off, *values)

    def layout(self):
        """Physical load addresses (each section page-aligned after the one before) and
        sectinfo: vaddr, paddr and size of .text, .data and .bss."""
        paddr = self.sec['pstart']['paddr'] + self.sec['pstart']['size']
        info = []
        for name in ('.text', '.data', '.bss'):
            paddr = align(paddr, PAGE)
            s = self.sec[name]
            info += [s['vaddr'], paddr, s['size']]
            paddr += s['size']
        return info

    def check_layout(self):
        info = self.layout()
        have = [x for n in ('.text', '.data', '.bss') for x in
                (self.sec[n]['vaddr'], self.sec[n]['paddr'], self.sec[n]['size'])]
        if have != info:
            raise ValueError('section addresses %s, expected %s' % (have, info))
        if self.get(self.sym('sectinfo'), 9) != info:
            raise ValueError('sectinfo does not match the section headers')

    def update_layout(self):
        info = self.layout()
        for i, name in enumerate(('.text', '.data', '.bss')):
            self.sec[name]['paddr'] = info[3 * i + 1]
        self.put(self.sym('sectinfo'), *info)
        struct.pack_into('>iii', self.aout, 4, *(self.sec[n]['size']
                                                 for n in ('.text', '.data', '.bss')))

    def init_table(self, stage):
        """(address, number of slots) of an init_* table: null-terminated pointers,
        its size in the long that follows it (init_lastl ...)."""
        table = STAGES[stage]
        return self.sym(table), self.get(self.sym(table + 'l'))[0]

    def write(self):
        strtab = bytearray(4)

        def name8(name):
            b = name.encode('latin-1')
            if len(b) <= 8:
                return b.ljust(8, b'\0')
            off = len(strtab)
            strtab.extend(b + b'\0')
            return b'\0\0\0\0' + struct.pack('>I', off)

        syms = bytearray()
        for s in self.syms:
            if s['sclass'] == C_FILE and s['aux'] and s['aux'][0][:4] == bytes(4):
                raise ValueError('.file name in the string table')
            syms += name8(s['name']) + struct.pack('>ihHBB', s['value'], s['scnum'], s['type'],
                                                   s['sclass'], len(s['aux']))
            for a in s['aux']:
                syms += a
        struct.pack_into('>I', strtab, 0, len(strtab))

        out = bytearray()
        ptr = 20 + len(self.aout) + 40 * len(SECTIONS)
        hdrs = bytearray()
        for name in SECTIONS:
            s = self.sec[name]
            size = len(self.body[name]) if name in self.body else s['size']
            hdrs += name.encode().ljust(8, b'\0') + struct.pack(
                '>iiiiiiHHi', s['paddr'], s['vaddr'], size, ptr if name in self.body else 0,
                0, 0, 0, 0, s['flags'])
            if name in self.body:
                ptr += size
        out += struct.pack('>HHiiiHH', 0x0150, len(SECTIONS), self.timdat, ptr,
                           len(syms) // 18, len(self.aout), self.flags)
        out += self.aout + hdrs
        for name in SECTIONS:
            if name in self.body:
                out += self.body[name]
        return bytes(out + syms + strtab)


def link(k, mod, name, master_file, timdat=None, bss_base=None):
    """Link the module object MOD (bytes) into Kernel K under NAME; its .bss at the end
    of the kernel's, or at BSS_BASE (check: the hole unlink left)."""
    flags, prefix, major, units = master(master_file)
    bits, stage = parse_flags(flags)
    m = Coff(mod)
    if [s['name'] for s in m.sections] != ['.text', '.data', '.bss']:
        raise ValueError('module sections %s' % [s['name'] for s in m.sections])
    msec = {s['name']: s for s in m.sections}
    mlocal, mglobal = split_syms(read_syms(m))
    klocal, kglobal = split_syms(k.syms)
    kdef = {s['name']: s['value'] for s in kglobal if s['scnum'] != 0}
    mods = k.body['MODULES']
    if name in (mods[i:i + 20].rstrip(b'\0').decode() for i in range(0, len(mods), RECORD)):
        raise ValueError('%s is already linked into the kernel' % name)

    # placement: each section at the end of the kernel's, the commons after .bss
    base = {n: align(k.sec[n]['vaddr'] + k.sec[n]['size'], 4)
            for n in ('.text', '.data', '.bss')}
    bss_end = base['.bss']
    if bss_base is None:
        bss_end += msec['.bss']['size']
    else:
        base['.bss'] = bss_base
    common = {}
    for s in mglobal:
        if s['scnum'] == 0 and s['value'] and s['name'] not in kdef:
            bss_end = align(bss_end, 4)
            common[s['name']] = bss_end
            bss_end += s['value']
        elif s['scnum'] == 0 and not s['value'] and s['name'] not in kdef:
            raise ValueError('%s: undefined in the kernel' % s['name'])
        elif s['scnum'] > 0 and s['name'] in kdef:
            raise ValueError('%s: already defined in the kernel' % s['name'])

    def address(sym):
        return kdef[sym] if sym in kdef else common[sym]

    linked = m.link(base, address)
    for n in ('.text', '.data'):
        k.body[n] += bytes(base[n] - k.sec[n]['vaddr'] - len(k.body[n])) + linked.get(n, b'')
        k.sec[n]['size'] = len(k.body[n])
    k.sec['.bss']['size'] = bss_end - k.sec['.bss']['vaddr']
    k.update_layout()

    # symbols: the module's locals after the kernel's, its globals after the kernel's
    scn = {1: ('.text', 2), 2: ('.data', 3), 3: ('.bss', 4)}

    def relocate(s):
        s = dict(s)
        if s['scnum'] > 0:
            sec, s['scnum'] = scn[s['scnum']]
            s['value'] += base[sec] - msec[sec]['vaddr']
        return s

    if not mlocal or mlocal[0]['sclass'] != C_FILE:
        raise ValueError('module symbols do not start with .file')
    newlocal = [relocate(s) for s in kept_locals(mlocal)]
    newglobal = []
    for s in mglobal:
        if s['name'] in common:
            newglobal.append(dict(s, scnum=4, value=common[s['name']]))
        elif s['scnum'] != 0:
            newglobal.append(relocate(s))
    k.syms = klocal + newlocal + kglobal + newglobal
    chain_files(k.syms)

    # init routine, MODULES record
    if stage:
        init = next((s['value'] for s in newglobal if s['name'] == prefix + 'init'), None)
        if init is None:
            raise ValueError('module has no %sinit' % prefix)
        table, slots = k.init_table(stage)
        entries = k.get(table, slots)
        if 0 not in entries[:-1]:
            raise ValueError('%s is full' % STAGES[stage])
        k.put(table + 4 * entries.index(0), init)
    rec = bytearray(RECORD)
    rec[0:20] = name.encode().ljust(20, b'\0')
    struct.pack_into('>ii', rec, 0x14, major, 2)
    struct.pack_into('>i', rec, 0x28, bits)
    rec[0x2c:0x40] = prefix.encode().ljust(20, b'\0')
    struct.pack_into('>i', rec, 0x40, units)
    # autoconfig leaves the same stale buffer bytes at the end of every record
    rec[0x44:] = k.body['MODULES'][-RECORD + 0x44:]
    k.body['MODULES'] += rec
    k.sec['MODULES']['size'] = len(k.body['MODULES'])
    k.timdat = int(time.time()) if timdat is None else timdat
    return dict(text=base['.text'], data=base['.data'], bss=base['.bss'], common=common,
                init=init if stage else None)


def unlink(k, mod, name, master_file):
    """Take the module MOD, linked last into Kernel K, out of it again (for check)."""
    flags, prefix, major, units = master(master_file)
    bits, stage = parse_flags(flags)
    m = Coff(mod)
    msec = {s['name']: s for s in m.sections}
    mlocal, mglobal = split_syms(read_syms(m))
    klocal, kglobal = split_syms(k.syms)
    if k.body['MODULES'][-RECORD:-RECORD + 20].rstrip(b'\0').decode() != name:
        raise ValueError('%s is not the last module' % name)
    mlocal = kept_locals(mlocal)
    tlocal = klocal[-len(mlocal):]
    if [s['name'] for s in tlocal] != [s['name'] for s in mlocal]:
        raise ValueError("the kernel's last local symbols are not %s's" % name)
    # its globals, matched from the end: the defined ones, and those of its commons that
    # were allocated after its .bss (not the ones the kernel defines)
    tglobal, i = [], len(kglobal)
    for s in reversed(mglobal):
        if i and kglobal[i - 1]['name'] == s['name'] and (s['scnum'] > 0 or s['value']):
            i -= 1
            tglobal.insert(0, kglobal[i])
        elif s['scnum'] > 0:
            raise ValueError("the kernel's last globals are not %s's" % name)
    keep = i
    start = {n: k.sec[n]['vaddr'] + k.sec[n]['size'] - msec[n]['size']
             for n in ('.text', '.data')}
    if tlocal[1]['name'] != '.text' or tlocal[1]['value'] != start['.text']:
        raise ValueError('%s .text is not at the end of the kernel .text' % name)
    for n in ('.text', '.data'):
        del k.body[n][start[n] - k.sec[n]['vaddr']:]
        k.sec[n]['size'] = len(k.body[n])
    # .bss: its commons are the kernel's last; ld put its .bss before all the modules'
    # commons, so unless it is last as well that place stays as a hole
    bss_end = k.sec['.bss']['vaddr'] + k.sec['.bss']['size']
    mcommon = [t for t in tglobal if t['name'] in
               {s['name'] for s in mglobal if s['scnum'] == 0}]
    bss_end -= sum(align(s['value'], 4) for s in mglobal
                   if s['scnum'] == 0 and s['name'] in {t['name'] for t in mcommon})
    if any(t['value'] < bss_end for t in mcommon):
        raise ValueError("%s's commons are not at the end of the kernel .bss" % name)
    hole = next((t['value'] - s['value'] + msec['.bss']['vaddr']
                 for s, t in zip(mlocal, tlocal) if s['scnum'] == 3), None)
    if hole is None or hole + msec['.bss']['size'] == bss_end:
        bss_end -= msec['.bss']['size']
        hole = None
    k.sec['.bss']['size'] = bss_end - k.sec['.bss']['vaddr']
    old = k.get(k.sym('sectinfo'), 9)
    k.update_layout()
    if k.get(k.sym('sectinfo'), 9) == old:
        raise ValueError('sectinfo unchanged')
    k.syms = klocal[:-len(mlocal)] + kglobal[:keep]
    chain_files(k.syms)
    if stage:
        table, slots = k.init_table(stage)
        entries = k.get(table, slots)
        last = entries.index(0) - 1
        if entries[last] != next(s['value'] for s in tglobal if s['name'] == prefix + 'init'):
            raise ValueError('%sinit is not the last %s entry' % (prefix, STAGES[stage]))
        k.put(table + 4 * last, 0)
    del k.body['MODULES'][-RECORD:]
    k.sec['MODULES']['size'] = len(k.body['MODULES'])
    return hole


def main():
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    if sys.argv[1] == 'check':
        unix, mod, mfile = sys.argv[2:5]
        orig = open(unix, 'rb').read()
        modb = open(mod, 'rb').read()
        name = os.path.basename(mod)
        k = Kernel(orig)
        hole = unlink(k, modb, name, mfile)
        k = Kernel(k.write())             # the kernel without the module, as a file
        link(k, modb, name, mfile, timdat=Coff(orig).timdat, bss_base=hole)
        new = k.write()
        diff = [i for i in range(max(len(orig), len(new))) if orig[i:i + 1] != new[i:i + 1]]
        print('%s: %d bytes, %d differ%s%s' % (unix, len(orig), len(diff),
              (' at %s' % [hex(d) for d in diff[:16]]) if diff else '',
              ' (%s .bss linked back at %#x)' % (name, hole) if hole else ''))
        sys.exit(1 if diff else 0)
    unix, mod, mfile, out = sys.argv[1:5]
    k = Kernel(open(unix, 'rb').read())
    r = link(k, open(mod, 'rb').read(), os.path.basename(mod), mfile)
    open(out, 'wb').write(k.write())
    print('%s: .text %#x, .data %#x, .bss %#x%s%s' % (
        os.path.basename(mod), r['text'], r['data'], r['bss'],
        ', init %#x' % r['init'] if r['init'] else '',
        ''.join(', %s %#x' % c for c in r['common'].items())))


if __name__ == '__main__':
    main()
