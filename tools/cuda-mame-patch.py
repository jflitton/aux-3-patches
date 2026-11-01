#!/usr/bin/env python3
"""Describe the Cuda patch for tools/mame-605-probe.lua (applied in RAM at kernel _start).

  cuda-mame-patch.py KERNEL_COFF build/q605/kernel.elf build/q605/kernel.bin > build/cuda-NAME.lua

Kernel .text is loaded physically at the first 4KB page after pstart (endpstart rounded
up; 0x5c000 for 3.1), so a .text address maps to that + (addr - 0x10000000) while the
MMU is still off. The script prints the original bytes there so a wrong guess shows up.
"""
import os, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from coff import Coff  # noqa: E402

STUBS = [('shift_reg_intr', 'cuda_intr'), ('egret_reset', 'cuda_reset'),
         ('abort_pending_transactions', 'cuda_abort')]


def main():
    kernel, elf, binf = sys.argv[1:4]
    c = Coff(open(kernel, 'rb').read())
    ksym = {}
    for s in c.symbols:
        ksym.setdefault(s['name'], s['value'] & 0xffffffff)
    nm = subprocess.run(['m68k-elf-nm', elf], capture_output=True, text=True, check=True).stdout
    esym = {l.split()[2]: int(l.split()[0], 16) for l in nm.splitlines() if len(l.split()) == 3}
    text = [s for s in c.sections if s['name'] == '.text'][0]
    tphys = (ksym['endpstart'] + 0xfff) & ~0xfff
    phys = lambda a: tphys + a - text['vaddr']
    orig = lambda a, n: c.data[text['scnptr'] + a - text['vaddr']:][:n]
    base = ksym['cEgretDispatch']
    print('return {')
    print('  blob = "%s",' % os.path.abspath(binf))
    print('  blob_phys = 0x%x,' % phys(base))
    print('  check = { 0x%x, 0x%s },' % (phys(base), orig(base, 4).hex()))
    print('  stubs = {')
    for at, to in STUBS:
        print('    { 0x%x, 0x%x },  -- %s -> %s' % (phys(ksym[at]), esym[to], at, to))
    print('  },')
    print('}')


if __name__ == '__main__':
    main()
