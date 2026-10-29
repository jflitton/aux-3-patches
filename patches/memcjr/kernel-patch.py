#!/usr/bin/env python3
"""Generate the Quadra 605 kernel patch for an A/UX kernel (/unix or /etc/config.d/newunix).

  kernel-patch.py KERNEL ld                 kernel-specific link symbols (boardinit_switch)
  kernel-patch.py KERNEL spec ELF BIN BIN2 BIN3
                                            tools/binpatch.py spec, for /unix and newunix

The patch is the code linked by patches/memcjr/build.sh (src/cuda.c + src/boot605.S) placed
over cEgretDispatch, plus redirected call sites:

  cEgretDispatch                      the code itself (cuda_dispatch first)
  egret_reset+6                       .text2: the MMU-on hooks and their data
  shift_reg_intr, egret_reset,        jmp cuda_intr / cuda_reset / cuda_abort
    abort_pending_transactions
  boardinit: move.w machineID,d0;     jmp b605_switch (physical); 3 nops
    ext.l d0; bra.w <switch>
  _start: jsr boardinit               jsr b605_board (physical)
  vadrspace: jsr setup_lowmem_globals jsr b605_lowmem
  vadrspace: jsr setup_autovectors    jsr b605_vectors
  aEgretDispatch: jsr cEgretDispatch  jsr b605_egret
  memsize (no djMEMC/Orwell/RBV):     clr.l -(sp); jsr b605_banksize (physical)
    moveq #0,d0; move.l d0,-(sp);
    jsr banksize

A checkpoint build (CKPT=1, src/boot605.S) puts .text3 (checkpoint code, b605_sense with
checkpoints) over orwellsize in pstart, redirects _DAFBMonitorDetect's jsr DAFBReadSenseLines
to b605_sense (A/UX's sense code with checkpoints) and its jsr ReadExtendedSense to
ck_extsense, and, in /unix only (autoconfig writes these tables), init_first's
egret_init, video_init and fdb_init entries, main's jsr startup, and initfunc's iinit and
nvram_init entries to the ck_* trampolines.

Sites are found by symbol and instruction pattern, so the same tool serves 3.0.1 and 3.1.
autoconfig rewrites only configuration data, so /unix and the newunix it is linked from
take the same patch. Kernel .text is loaded physically at the first 4KB page after pstart
(endpstart rounded up); hooks that run with the MMU off are entered there.
"""
import os, struct, subprocess, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from binpatch import checksum  # noqa: E402
from coff import Coff  # noqa: E402

STUBS = [('shift_reg_intr', 'cuda_intr'), ('egret_reset', 'cuda_reset'),
         ('abort_pending_transactions', 'cuda_abort')]
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

    def memsize_banksize(self):
        """memsize's banksize call on the path after 'tst.l rbv_exists; bne.w':
        address of its 'moveq #0,d0; move.l d0,-(sp); jsr banksize(pc)'."""
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
        return site


def elf_symbols(elf):
    nm = subprocess.run(['m68k-elf-nm', elf], capture_output=True, text=True, check=True).stdout
    return {l.split()[2]: int(l.split()[0], 16) for l in nm.splitlines() if len(l.split()) == 3}


def main():
    k, cmd = Kernel(sys.argv[1]), sys.argv[2]
    if cmd == 'ld':
        print('boardinit_switch = 0x%08x;' % k.boardinit_switch()[1])
        return
    esym, blob = elf_symbols(sys.argv[3]), open(sys.argv[4], 'rb').read()
    blob2, blob3 = open(sys.argv[5], 'rb').read(), open(sys.argv[6], 'rb').read()
    if esym['cuda_dispatch'] != k.sym['cEgretDispatch']:
        raise SystemExit('cuda_dispatch is not at cEgretDispatch')
    switch_site, _ = k.boardinit_switch()
    sites = [
        (k.sym['cEgretDispatch'], blob, 'Cuda transport and 605 boot hooks (%d bytes)' % len(blob)),
        (k.sym['egret_reset'] + 6, blob2, 'MMU-on boot hooks and data (%d bytes)' % len(blob2)),
    ] + [
        (k.sym[at], JMP + struct.pack('>I', esym[to]), 'jmp %s' % to) for at, to in STUBS
    ] + [
        (switch_site, JMP + struct.pack('>I', k.phys(esym['b605_switch'])) + NOP * 3,
         'jmp b605_switch (physical %#x)' % k.phys(esym['b605_switch'])),
        (k.find('pstart', JSR + struct.pack('>I', k.sym['boardinit'])),
         JSR + struct.pack('>I', k.phys(esym['b605_board'])),
         'jsr b605_board (physical %#x), was boardinit' % k.phys(esym['b605_board'])),
        (k.find('pstart', JSR + struct.pack('>I', k.sym['setup_lowmem_globals'])),
         JSR + struct.pack('>I', esym['b605_lowmem']), 'jsr b605_lowmem, was setup_lowmem_globals'),
        (k.find('pstart', JSR + struct.pack('>I', k.sym['setup_autovectors'])),
         JSR + struct.pack('>I', esym['b605_vectors']), 'jsr b605_vectors, was setup_autovectors'),
        (k.memsize_banksize(), CLR_SP + JSR + struct.pack('>I', k.phys(esym['b605_banksize'])),
         'clr.l -(sp); jsr b605_banksize (physical %#x), was banksize' %
         k.phys(esym['b605_banksize'])),
    ]
    egret = k.sym['aEgretDispatch'] + 2
    if k.read(egret, 6) != JSR + struct.pack('>I', k.sym['cEgretDispatch']):
        raise SystemExit('aEgretDispatch+2 is not jsr cEgretDispatch')
    sites.append((egret, JSR + struct.pack('>I', esym['b605_egret']),
                  'jsr b605_egret, was cEgretDispatch'))
    if blob3:
        sites += [
            (k.sym['orwellsize'], blob3, 'checkpoint code (%d bytes)' % len(blob3)),
            (k.find('pstart', JSR + struct.pack('>I', k.sym['DAFBReadSenseLines'])),
             JSR + struct.pack('>I', k.entry(esym['b605_sense'])),
             'jsr b605_sense (%#x), was DAFBReadSenseLines' % k.entry(esym['b605_sense'])),
            (k.find('pstart', JSR + struct.pack('>I', k.sym['ReadExtendedSense'])),
             JSR + struct.pack('>I', esym['ck_extsense']), 'jsr ck_extsense, was ReadExtendedSense'),
        ]
    print('; Quadra 605 kernel patch, generated by patches/memcjr/kernel-patch.py from %s' %
          os.path.basename(sys.argv[1]))
    print('; Apply with tools/binpatch.py; /unix and the newunix autoconfig links it from.')
    print('file /unix /etc/config.d/newunix')
    emit(k, sites)
    if 'ck_startup' in esym:
        ptr = lambda name: struct.pack('>I', esym[name])
        print()
        print('; checkpoint build: hold a checkpoint key through "Launching" to restart there')
        print('file /unix')
        emit(k, [(k.table_entry('init_first', f), ptr('ck_' + f), 'init_first: ck_' + f)
                 for f in ('egret_init', 'video_init', 'fdb_init')] + [
            (k.find('.text', JSR + struct.pack('>I', k.sym['startup'])),
             JSR + ptr('ck_startup'), 'main: jsr ck_startup, was startup')] + [
            (k.table_entry('initfunc', f), ptr('ck_' + f), 'initfunc: ck_' + f)
            for f in ('iinit', 'nvram_init')])


def emit(k, sites):
    for va, new, what in sites:
        print()
        print('at %s  ; %#x: %s' % (k.label(va), va, what))
        print('check %s' % checksum(k.read(va, len(new))))
        for i in range(0, len(new), 32):
            print('new ' + new[i:i + 32].hex(' ', 2))


if __name__ == '__main__':
    main()
