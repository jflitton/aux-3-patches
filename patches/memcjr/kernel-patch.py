#!/usr/bin/env python3
"""Generate the MEMCjr kernel patch (Quadra 605; LC/Performa 475, untested) for an A/UX
kernel (/unix or /etc/config.d/newunix).

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

Sites are found by symbol and instruction pattern (tools/kpatch.py), so the same tool
serves 3.0.1 and 3.1. autoconfig rewrites only configuration data, so /unix and the
newunix it is linked from take the same patch. Hooks that run with the MMU off are
entered at their physical addresses.
"""
import os, struct, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from kpatch import CLR_SP, JMP, JSR, NOP, Kernel, elf_symbols, emit  # noqa: E402

STUBS = [('shift_reg_intr', 'cuda_intr'), ('egret_reset', 'cuda_reset'),
         ('abort_pending_transactions', 'cuda_abort')]


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
        (k.sym['cEgretDispatch'], blob, 'Cuda transport and boot hooks (%d bytes)' % len(blob)),
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
    print('; MEMCjr kernel patch (Quadra 605, LC/Performa 475), generated by')
    print('; patches/memcjr/kernel-patch.py from %s' % os.path.basename(sys.argv[1]))
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


if __name__ == '__main__':
    main()
