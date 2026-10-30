#!/usr/bin/env python3
"""Add or replace files and make directories on an A/UX UFS partition (big-endian
4.2/4.3BSD FFS), and check its allocation metadata.

  ufsput.py IMAGE PART check
        fsck-style consistency check of PART: every inode's blocks against the free
        maps, and the free counts, fragment summaries and rotational tables against
        the maps. Read-only.
  ufsput.py IMAGE PART put SRC PATH [MODE [UID GID]] [--apply]
        create PATH (its directory must exist) or replace its contents with SRC.
        A new file gets MODE (octal, default 644) and UID/GID (default 0 0), a replaced
        one keeps its own unless they are given. Direct and single indirect blocks only
        (12 + NINDIR blocks: 16MB with 8KB blocks), for SRC and for a replaced file.
  ufsput.py IMAGE PART mkdir PATH [MODE [UID GID]] [--apply]
        make the directory PATH (its parent must exist, PATH must not), as mkdir(2)
        would: MODE default 755, UID/GID default 0 0.

Without --apply nothing is written (throwaway clones only, as for binpatch.py). The
allocator follows the 4.3BSD rules: full blocks are counted in cs_nbfree and the
rotational tables, the free fragments of a partial block in cs_nffree and cg_frsum.
"""
import os, stat, struct, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ufs import UFS

NDADDR, NRPOS, DIRBLKSIZ = 12, 8, 512
CG_MAGIC = 0x090255
CG_CS, CG_FRSUM, CG_BTOT, CG_B, CG_IUSED, CG_MAGIC_OFF, CG_FREE = 24, 52, 84, 212, 724, 980, 984
SB_CSADDR, SB_CSTOTAL = 152, 192


def dirsize(namlen):
    return 8 + ((namlen + 1 + 3) & ~3)


class Writer(UFS):
    def __init__(self, path, part, write=False):
        super().__init__(path, part)
        if write:
            self.f = open(path, 'r+b')
        self.sb = bytearray(self.read(8192, 8192))
        sb = self.sb
        (self.nspf,) = struct.unpack('>i', sb[124:128])
        self.csaddr, self.cssize, self.cgsize = struct.unpack('>3i', sb[152:164])
        self.nsect, self.spc = struct.unpack('>2i', sb[168:176])
        self.cg = {}

    def write(self, off, data):
        self.f.seek(self.base + off)
        self.f.write(data)

    # --- cylinder groups -------------------------------------------------------------

    def cgblk(self, c):
        if c not in self.cg:
            b = bytearray(self.read(self.frag_off(self.cgstart(c) + self.cblkno), self.cgsize))
            if struct.unpack('>I', b[CG_MAGIC_OFF:CG_MAGIC_OFF + 4])[0] != CG_MAGIC:
                raise ValueError('bad cylinder group %d' % c)
            self.cg[c] = b
        return self.cg[c]

    def csum(self):
        return bytearray(self.read(self.frag_off(self.csaddr), self.cssize))

    def isfree(self, cg, f):
        return cg[CG_FREE + f // 8] >> (f % 8) & 1

    def setfree(self, cg, f, free):
        if free:
            cg[CG_FREE + f // 8] |= 1 << (f % 8)
        else:
            cg[CG_FREE + f // 8] &= ~(1 << (f % 8))

    def cylpos(self, bno):
        return (bno * self.nspf // self.spc,
                bno * self.nspf % self.spc % self.nsect * NRPOS // self.nsect)

    def blockacct(self, cg, bno, cnt, totals):
        """Count block BNO (cg-relative fragment of its start) as it stands, CNT = +1 or
        -1: cg header, and the per-field deltas collected in TOTALS (for csum, sb)."""
        bits = [self.isfree(cg, bno + i) for i in range(self.frag)]
        if all(bits):
            self.add(cg, CG_CS + 4, cnt)
            totals['nbfree'] += cnt
            cyl, pos = self.cylpos(bno)
            self.add(cg, CG_BTOT + 4 * cyl, cnt)
            self.add(cg, CG_B + 2 * (NRPOS * cyl + pos), cnt, '>h')
        else:
            n = sum(bits)
            self.add(cg, CG_CS + 12, cnt * n)
            totals['nffree'] += cnt * n
            run = 0
            for b in bits + [0]:
                if b:
                    run += 1
                elif run:
                    self.add(cg, CG_FRSUM + 4 * run, cnt)
                    run = 0

    @staticmethod
    def add(buf, off, delta, fmt='>i'):
        struct.pack_into(fmt, buf, off, struct.unpack_from(fmt, buf, off)[0] + delta)

    def setfrags(self, c, bno, frags, free, totals):
        """Mark FRAGS fragments from cg-relative BNO free or used, keeping the counts."""
        cg = self.cgblk(c)
        start = bno - bno % self.frag
        self.blockacct(cg, start, -1, totals)
        for f in range(bno, bno + frags):
            if self.isfree(cg, f) == free:
                raise ValueError('fragment %d of cg %d already %s' % (f, c, 'free' if free else 'used'))
            self.setfree(cg, f, free)
        self.blockacct(cg, start, +1, totals)

    def allocblock(self, c0, totals):
        """A fully free block, searching from cg C0; returns its fs fragment number."""
        for k in range(self.ncg):
            c = (c0 + k) % self.ncg
            cg = self.cgblk(c)
            ndblk = struct.unpack('>i', cg[20:24])[0]
            for bno in range(0, ndblk - self.frag + 1, self.frag):
                if all(self.isfree(cg, bno + i) for i in range(self.frag)):
                    return c, bno
        raise ValueError('file system full')

    # --- inodes and directories ------------------------------------------------------

    def inode_off(self, ino):
        c = ino // self.ipg
        fragno = self.cgstart(c) + self.iblkno + ((ino % self.ipg) // self.inopb) * self.frag
        return self.frag_off(fragno) + (ino % self.inopb) * 128

    def allocinode(self, c0, totals):
        for k in range(self.ncg):
            c = (c0 + k) % self.ncg
            cg = self.cgblk(c)
            for i in range(self.ipg):
                if c == 0 and i < 3:
                    continue
                if not cg[CG_IUSED + i // 8] >> (i % 8) & 1:
                    cg[CG_IUSED + i // 8] |= 1 << (i % 8)
                    self.add(cg, CG_CS + 8, -1)
                    totals['nifree'] -= 1
                    return c * self.ipg + i
        raise ValueError('no free inodes')

    def file_frags(self, ino, meta=False):
        """(fs fragment, count) runs of a regular file's or directory's data blocks, and
        with META its single indirect block too. Past NDADDR blocks there are no
        fragments."""
        if any(ino['ib'][1:]):
            raise ValueError('inode %d has double or triple indirect blocks' % ino['ino'])
        size = ino['size']
        out = []
        for lbn, p in enumerate(self.block_list(ino)):
            rest = size - lbn * self.bsize
            n = self.frag if lbn >= NDADDR or rest >= self.bsize else \
                (rest + self.fsize - 1) // self.fsize
            if p:
                out.append((p, n))
        if meta and ino['ib'][0]:
            out.append((ino['ib'][0], self.frag))
        return out

    def put(self, src, path, mode=None, uid=None, gid=None):
        data = open(src, 'rb').read()
        if len(data) > (NDADDR + self.nindir) * self.bsize:
            raise ValueError('%s: more than %d blocks' % (src, NDADDR + self.nindir))
        dirpath, name = os.path.split('/' + path.strip('/'))
        dino = self.lookup(dirpath)
        if not stat.S_ISDIR(dino['mode']):
            raise ValueError('%s is not a directory' % dirpath)
        totals = dict(ndir=0, nbfree=0, nffree=0, nifree=0)
        touched = set()
        now = int(time.time())
        existing = dict(self.readdir(dino)).get(name)
        if existing:
            old = self.inode(existing)
            if not stat.S_ISREG(old['mode']):
                raise ValueError('%s exists and is not a regular file' % path)
            for fragno, n in self.file_frags(old, meta=True):
                c = fragno // self.fpg
                self.setfrags(c, fragno % self.fpg, n, True, self.tally(totals, c, touched))
            raw = bytearray(old['raw'])
            ino = existing
            if mode is not None:
                struct.pack_into('>H', raw, 0, stat.S_IFREG | mode)
            if uid is not None:
                struct.pack_into('>HH', raw, 4, uid, gid)
        else:
            c = dino['ino'] // self.ipg
            ino = self.allocinode(c, totals)
            touched.add(ino // self.ipg)
            raw = bytearray(128)
            struct.pack_into('>HhHH', raw, 0, stat.S_IFREG | (0o644 if mode is None else mode), 1,
                             uid or 0, gid or 0)
            struct.pack_into('>i', raw, 108, int.from_bytes(os.urandom(4), 'big') >> 1)
        # data: full blocks, then a tail within the direct blocks as fragments of a
        # fresh block; past them, whole blocks listed in a single indirect block
        nblk = (len(data) + self.bsize - 1) // self.bsize
        blocks = []
        nfrags = 0
        c0 = ino // self.ipg

        def alloc(n):
            c, bno = self.allocblock(c0, totals)
            self.setfrags(c, bno, n, False, self.tally(totals, c, touched))
            return c * self.fpg + bno

        for lbn in range(nblk):
            chunk = data[lbn * self.bsize:(lbn + 1) * self.bsize]
            n = self.frag if lbn >= NDADDR else (len(chunk) + self.fsize - 1) // self.fsize
            fragno = alloc(n)
            self.write(self.frag_off(fragno), chunk + bytes(n * self.fsize - len(chunk)))
            blocks.append(fragno)
            nfrags += n
        ib = 0
        if nblk > NDADDR:
            ib = alloc(self.frag)
            ptrs = blocks[NDADDR:] + [0] * (self.nindir - (nblk - NDADDR))
            self.write(self.frag_off(ib), struct.pack('>%di' % self.nindir, *ptrs))
            nfrags += self.frag
        db = (blocks + [0] * NDADDR)[:NDADDR]
        struct.pack_into('>ii', raw, 8, 0, len(data))
        struct.pack_into('>iiiiii', raw, 16, now, 0, now, 0, now, 0)
        struct.pack_into('>12i', raw, 40, *db)
        struct.pack_into('>3i', raw, 88, ib, 0, 0)
        struct.pack_into('>i', raw, 104, nfrags * self.fsize // 512)
        self.write(self.inode_off(ino), bytes(raw))
        if not existing:
            self.adddirent(dino, name, ino)
        self.flush(totals, touched)
        return ino

    def mkdir(self, path, mode=0o755, uid=0, gid=0):
        dirpath, name = os.path.split('/' + path.strip('/'))
        pino = self.lookup(dirpath)
        if not stat.S_ISDIR(pino['mode']):
            raise ValueError('%s is not a directory' % dirpath)
        if name in dict(self.readdir(pino)):
            raise ValueError('%s exists' % path)
        totals = dict(ndir=1, nbfree=0, nffree=0, nifree=0)
        touched = set()
        now = int(time.time())
        ino = self.allocinode(pino['ino'] // self.ipg, totals)
        c = ino // self.ipg
        touched.add(c)
        self.add(self.cgblk(c), CG_CS, 1)
        # one directory block (DIRBLKSIZ) in a fragment of a fresh block, as 4.3BSD's
        # mkdir makes it: "." and ".."
        cb, bno = self.allocblock(c, totals)
        self.setfrags(cb, bno, 1, False, self.tally(totals, cb, touched))
        fragno = cb * self.fpg + bno
        blk = struct.pack('>IHH4s', ino, 12, 1, b'.') + \
            struct.pack('>IHH4s', pino['ino'], DIRBLKSIZ - 12, 2, b'..')
        self.write(self.frag_off(fragno), blk.ljust(self.fsize, b'\0'))
        raw = bytearray(128)
        struct.pack_into('>HhHH', raw, 0, stat.S_IFDIR | mode, 2, uid, gid)
        struct.pack_into('>ii', raw, 8, 0, DIRBLKSIZ)
        struct.pack_into('>iiiiii', raw, 16, now, 0, now, 0, now, 0)
        struct.pack_into('>i', raw, 40, fragno)
        struct.pack_into('>i', raw, 104, self.fsize // 512)
        struct.pack_into('>i', raw, 108, int.from_bytes(os.urandom(4), 'big') >> 1)
        self.write(self.inode_off(ino), bytes(raw))
        self.adddirent(pino, name, ino)
        # the new ".." is a link to the parent
        praw = bytearray(pino['raw'])
        self.add(praw, 2, 1, '>h')
        self.write(self.inode_off(pino['ino']), bytes(praw))
        self.flush(totals, touched)
        return ino

    def tally(self, totals, c, touched):
        touched.add(c)
        return totals

    def adddirent(self, dino, name, ino):
        need = dirsize(len(name))
        for fragno, n in self.file_frags(dino):
            blk = bytearray(self.read(self.frag_off(fragno), n * self.fsize))
            for chunk in range(0, len(blk), DIRBLKSIZ):
                off = chunk
                while off < chunk + DIRBLKSIZ:
                    eino, reclen, namlen = struct.unpack_from('>IHH', blk, off)
                    if reclen == 0:
                        break
                    used = dirsize(namlen) if eino else 0
                    if reclen - used >= need:
                        if eino:
                            struct.pack_into('>H', blk, off + 4, used)
                            new = off + used
                            reclen -= used
                        else:
                            new = off
                        enc = name.encode('latin-1')
                        struct.pack_into('>IHH', blk, new, ino, reclen, len(enc))
                        blk[new + 8:new + 8 + need - 8] = enc.ljust(need - 8, b'\0')
                        self.write(self.frag_off(fragno), bytes(blk))
                        return
                    off += reclen
        raise ValueError('no room in directory for %s' % name)

    def flush(self, totals, touched):
        cs = self.csum()
        for c in touched:
            cg = self.cgblk(c)
            struct.pack_into('>16s', cs, 16 * c, bytes(cg[CG_CS:CG_CS + 16]))
            self.write(self.frag_off(self.cgstart(c) + self.cblkno), bytes(cg))
        self.write(self.frag_off(self.csaddr), bytes(cs))
        for field, off in (('ndir', 0), ('nbfree', 4), ('nifree', 8), ('nffree', 12)):
            self.add(self.sb, SB_CSTOTAL + off, totals[field])
        struct.pack_into('>i', self.sb, 32, int(time.time()))
        self.write(8192, bytes(self.sb[:struct.unpack('>i', self.sb[104:108])[0]]))

    # --- check ---------------------------------------------------------------------

    def check(self):
        problems = []
        owner = {}
        cs = self.csum()
        ndir = [0] * self.ncg
        nused = [0] * self.ncg

        def claim(fragno, n, ino):
            for f in range(fragno, fragno + n):
                if f in owner:
                    problems.append('fragment %d in inodes %d and %d' % (f, owner[f], ino))
                owner[f] = ino

        for c in range(self.ncg):
            # metadata: superblock copy to first data block (cg 0: from the boot blocks
            # on, and the summary area); blocks before the copy are ordinary data
            for f in range(self.cgstart(c) + self.sblkno if c else 0,
                           self.cgstart(c) + self.dblkno):
                owner[f] = -1
            if c == 0:
                for f in range(self.csaddr, self.csaddr +
                               (self.cssize + self.fsize - 1) // self.fsize):
                    owner[f] = -1
            raw = self.read(self.frag_off(self.cgstart(c) + self.iblkno), self.ipg * 128)
            cg = self.cgblk(c)
            for i in range(self.ipg):
                d = raw[i * 128:(i + 1) * 128]
                ino = c * self.ipg + i
                mode = struct.unpack('>H', d[0:2])[0]
                used = cg[CG_IUSED + i // 8] >> (i % 8) & 1
                if (mode != 0) != bool(used) and not (c == 0 and i < 2):
                    problems.append('inode %d: mode %o but map says %s' % (
                        ino, mode, 'used' if used else 'free'))
                if not mode:
                    continue
                nused[c] += 1
                if stat.S_ISDIR(mode):
                    ndir[c] += 1
                blocks = struct.unpack('>i', d[104:108])[0]
                if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode)) \
                        or blocks == 0:
                    continue
                inode = self.inode(ino)
                nfr = 0
                size = inode['size']
                for lbn, p in enumerate(self.block_list(inode)):
                    if not p:
                        continue
                    rest = size - lbn * self.bsize
                    n = self.frag if lbn >= NDADDR or rest >= self.bsize else \
                        (rest + self.fsize - 1) // self.fsize
                    claim(p, n, ino)
                    nfr += n
                nfr += self.claim_indirect(inode['ib'], ino, claim)
                if nfr * self.fsize // 512 != blocks:
                    problems.append('inode %d: di_blocks %d, owns %d sectors' % (
                        ino, blocks, nfr * self.fsize // 512))
        tot = dict(ndir=0, nbfree=0, nifree=0, nffree=0)
        for c in range(self.ncg):
            cg = self.cgblk(c)
            base = self.cgbase(c)
            ndblk = struct.unpack('>i', cg[20:24])[0]
            nbfree = nffree = 0
            frsum = [0] * 8
            btot = [0] * 32
            b = [[0] * NRPOS for _ in range(32)]
            for bno in range(0, ndblk, self.frag):
                bits = []
                for i in range(self.frag):
                    f = bno + i
                    free = self.isfree(cg, f) if f < ndblk else 0
                    if free and base + f in owner:
                        problems.append('fragment %d (cg %d) free but used by inode %d' % (
                            base + f, c, owner[base + f]))
                    if not free and f < ndblk and base + f not in owner:
                        problems.append('fragment %d (cg %d) allocated but unreferenced' % (base + f, c))
                    bits.append(free)
                if all(bits):
                    nbfree += 1
                    cyl, pos = self.cylpos(bno)
                    btot[cyl] += 1
                    b[cyl][pos] += 1
                else:
                    nffree += sum(bits)
                    run = 0
                    for x in bits + [0]:
                        if x:
                            run += 1
                        elif run:
                            frsum[run] += 1
                            run = 0
            nifree = self.ipg - nused[c] - (2 if c == 0 else 0)
            want = dict(ndir=ndir[c], nbfree=nbfree, nifree=nifree, nffree=nffree)
            have = dict(zip(('ndir', 'nbfree', 'nifree', 'nffree'),
                            struct.unpack('>4i', cg[CG_CS:CG_CS + 16])))
            have_cs = dict(zip(('ndir', 'nbfree', 'nifree', 'nffree'),
                               struct.unpack('>4i', cs[16 * c:16 * c + 16])))
            if want != have:
                problems.append('cg %d summary %s, maps say %s' % (c, have, want))
            if have_cs != have:
                problems.append('cg %d csum area %s, cg says %s' % (c, have_cs, have))
            if list(struct.unpack('>8i', cg[CG_FRSUM:CG_FRSUM + 32]))[1:] != frsum[1:]:
                problems.append('cg %d frsum %s, maps say %s' % (
                    c, struct.unpack('>8i', cg[CG_FRSUM:CG_FRSUM + 32]), frsum))
            if list(struct.unpack('>32i', cg[CG_BTOT:CG_BTOT + 128])) != btot:
                problems.append('cg %d btot differs' % c)
            if list(struct.unpack('>256h', cg[CG_B:CG_B + 512])) != sum(b, []):
                problems.append('cg %d rotational table differs' % c)
            for k in tot:
                tot[k] += want[k]
        have = dict(zip(('ndir', 'nbfree', 'nifree', 'nffree'),
                        struct.unpack('>4i', self.sb[SB_CSTOTAL:SB_CSTOTAL + 16])))
        if have != tot:
            # not a problem: A/UX leaves fs_cstotal as mkfs wrote it (seen on the
            # Shoebill 3.1 image: 2 directories, 17 free fragments)
            print('note: superblock totals %s, cgs say %s' % (have, tot))
        return problems

    def claim_indirect(self, ib, ino, claim):
        n = 0
        for level, p in enumerate(ib):
            n += self._claim_ind(p, level, ino, claim)
        return n

    def _claim_ind(self, p, level, ino, claim):
        if not p:
            return 0
        claim(p, self.frag, ino)
        n = self.frag
        if level:
            ptrs = struct.unpack('>%di' % self.nindir, self.read(self.frag_off(p), self.bsize))
            for q in ptrs:
                n += self._claim_ind(q, level - 1, ino, claim)
        return n

    def cgbase(self, c):
        return self.fpg * c


def main():
    img, part, cmd = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    args = [a for a in sys.argv[4:] if a != '--apply']
    apply = '--apply' in sys.argv
    if cmd == 'check':
        problems = Writer(img, part).check()
        for p in problems[:50]:
            print(p)
        print('%d problems' % len(problems))
        sys.exit(1 if problems else 0)
    if cmd == 'put':
        w = Writer(img, part, write=apply)
        if not apply:
            w.write = lambda off, data: None
        mode = int(args[2], 8) if len(args) > 2 else None
        uid, gid = (int(args[3]), int(args[4])) if len(args) > 4 else (None, None)
        ino = w.put(args[0], args[1], mode, uid, gid)
        print('%s: inode %d%s' % (args[1], ino, '' if apply else ' (not written: no --apply)'))
        return
    if cmd == 'mkdir':
        w = Writer(img, part, write=apply)
        if not apply:
            w.write = lambda off, data: None
        mode = int(args[1], 8) if len(args) > 1 else 0o755
        uid, gid = (int(args[2]), int(args[3])) if len(args) > 3 else (0, 0)
        ino = w.mkdir(args[0], mode, uid, gid)
        print('%s: inode %d%s' % (args[0], ino, '' if apply else ' (not written: no --apply)'))
        return
    raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
