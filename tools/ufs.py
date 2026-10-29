#!/usr/bin/env python3
"""Read-only access to A/UX UFS (big-endian 4.2/4.3BSD FFS) partitions inside an
Apple-partitioned disk image.

  ufs.py IMAGE parts                      list the partition map
  ufs.py IMAGE find TEXT                  "PART START BLOCKS" of the one partition whose
                                          name or type contains TEXT
  ufs.py IMAGE ls    PART [PATH]          recursive listing (manifest)
  ufs.py IMAGE cat   PART PATH > out      write one file to stdout
  ufs.py IMAGE extract PART DESTDIR       extract regular files, dirs, symlinks
  ufs.py IMAGE where PART PATH OFFSET     image byte offset of one byte of a file

PART is the 1-based partition-map index. The image is always opened read-only.
"""
import os, stat, struct, sys

SECTOR = 512


def apm(path):
    with open(path, 'rb') as f:
        f.seek(SECTOR)
        n = struct.unpack('>I', f.read(8)[4:8])[0]
        out = []
        for i in range(n):
            f.seek(SECTOR * (1 + i))
            e = f.read(SECTOR)
            start, count = struct.unpack('>II', e[8:16])
            name = e[16:48].split(b'\0')[0].decode('mac_roman')
            typ = e[48:80].split(b'\0')[0].decode('mac_roman')
            out.append((i + 1, name, typ, start, count))
        return out


class UFS:
    def __init__(self, path, part):
        entry = [p for p in apm(path) if p[0] == part][0]
        self.base = entry[3] * SECTOR
        self.f = open(path, 'rb')
        sb = self.read(8192, 1376)
        (self.sblkno, self.cblkno, self.iblkno, self.dblkno, self.cgoffset,
         self.cgmask) = struct.unpack('>6i', sb[8:32])
        self.ncg, self.bsize, self.fsize, self.frag = struct.unpack('>4i', sb[44:60])
        self.nindir, self.inopb = struct.unpack('>2i', sb[116:124])
        self.ipg, self.fpg = struct.unpack('>2i', sb[184:192])
        if struct.unpack('>I', sb[1372:1376])[0] != 0x011954:
            raise ValueError('no UFS superblock in partition %d' % part)

    def read(self, off, n):
        self.f.seek(self.base + off)
        return self.f.read(n)

    def frag_off(self, fragno):
        return fragno * self.fsize

    def cgstart(self, c):
        return self.fpg * c + self.cgoffset * (c & ~self.cgmask)

    def inode(self, ino):
        c = ino // self.ipg
        fragno = self.cgstart(c) + self.iblkno + ((ino % self.ipg) // self.inopb) * self.frag
        d = self.read(self.frag_off(fragno) + (ino % self.inopb) * 128, 128)
        mode, nlink, uid, gid = struct.unpack('>HhHH', d[0:8])
        size = struct.unpack('>I', d[12:16])[0]  # A/UX uses only the low word of di_qsize
        mtime = struct.unpack('>i', d[24:28])[0]
        db = struct.unpack('>12i', d[40:88])
        ib = struct.unpack('>3i', d[88:100])
        blocks = struct.unpack('>i', d[104:108])[0]
        return dict(ino=ino, mode=mode, nlink=nlink, uid=uid, gid=gid, size=size,
                    mtime=mtime, db=db, ib=ib, blocks=blocks, raw=d)

    def _indirect(self, blk, level, out, want):
        if len(out) >= want:
            return
        ptrs = struct.unpack('>%di' % self.nindir, self.read(self.frag_off(blk), self.bsize))
        for p in ptrs:
            if len(out) >= want:
                return
            if level == 0:
                out.append(p)
            elif p:
                self._indirect(p, level - 1, out, want)
            else:
                out.extend([0] * min(want - len(out), self.nindir ** level))

    def block_list(self, ino):
        nblk = (ino['size'] + self.bsize - 1) // self.bsize
        out = list(ino['db'][:nblk])
        for level, p in enumerate(ino['ib']):
            if len(out) >= nblk:
                break
            if p:
                self._indirect(p, level, out, nblk)
            else:
                out.extend([0] * min(nblk - len(out), self.nindir ** (level + 1)))
        return out[:nblk]

    def data(self, ino):
        size = ino['size']
        buf = bytearray()
        for b in self.block_list(ino):
            n = min(self.bsize, size - len(buf))
            buf += self.read(self.frag_off(b), n) if b else bytes(n)
        return bytes(buf)

    def image_offset(self, ino, off):
        """Byte offset in the image file of byte OFF of the file (None for a hole)."""
        b = self.block_list(ino)[off // self.bsize]
        return self.base + self.frag_off(b) + off % self.bsize if b else None

    def readdir(self, ino):
        d = self.data(ino)
        off, out = 0, []
        while off < len(d):
            dino, reclen, namlen = struct.unpack('>IHH', d[off:off + 8])
            if reclen == 0:
                off = (off // 512 + 1) * 512
                continue
            if dino:
                out.append((d[off + 8:off + 8 + namlen].decode('latin-1'), dino))
            off += reclen
        return out

    def lookup(self, path):
        ino = self.inode(2)
        for comp in [c for c in path.split('/') if c]:
            ents = dict(self.readdir(ino))
            if comp not in ents:
                raise FileNotFoundError(path)
            ino = self.inode(ents[comp])
        return ino

    def walk(self, path='/', ino=None):
        ino = ino or self.lookup(path)
        yield path, ino
        if stat.S_ISDIR(ino['mode']):
            for name, dino in sorted(self.readdir(ino)):
                if name in ('.', '..'):
                    continue
                yield from self.walk(os.path.join(path, name), self.inode(dino))


def main():
    img, cmd = sys.argv[1], sys.argv[2]
    if cmd == 'parts':
        for p in apm(img):
            print('%2d %-32s %-22s start=%-8d blocks=%d' % p)
        return
    if cmd == 'find':
        hits = [p for p in apm(img) if sys.argv[3] in p[1] or sys.argv[3] in p[2]]
        if len(hits) != 1:
            raise SystemExit('%d partitions match %r' % (len(hits), sys.argv[3]))
        print('%d %d %d' % (hits[0][0], hits[0][3], hits[0][4]))
        return
    fs = UFS(img, int(sys.argv[3]))
    if cmd == 'ls':
        for path, ino in fs.walk(sys.argv[4] if len(sys.argv) > 4 else '/'):
            extra = ''
            if stat.S_ISLNK(ino['mode']):
                extra = ' -> ' + fs.data(ino).decode('latin-1')
            size = '%9d' % ino['size']
            if stat.S_ISCHR(ino['mode']) or stat.S_ISBLK(ino['mode']):
                rdev = ino['db'][0]  # device number lives in di_db[0]
                size = '%5d,%3d' % ((rdev >> 8) & 0xff, rdev & 0xff)
            print('%s %3d %5d %5d %s %s%s' % (stat.filemode(ino['mode']), ino['nlink'],
                  ino['uid'], ino['gid'], size, path, extra))
    elif cmd == 'cat':
        sys.stdout.buffer.write(fs.data(fs.lookup(sys.argv[4])))
    elif cmd == 'where':
        print('%#x' % fs.image_offset(fs.lookup(sys.argv[4]), int(sys.argv[5], 0)))
    elif cmd == 'extract':
        dest = sys.argv[4]
        for path, ino in fs.walk('/'):
            out = os.path.join(dest, path.lstrip('/'))
            m = ino['mode']
            if stat.S_ISDIR(m):
                os.makedirs(out, exist_ok=True)
            elif stat.S_ISREG(m):
                with open(out, 'wb') as o:
                    o.write(fs.data(ino))
                os.chmod(out, 0o644)
            elif stat.S_ISLNK(m):
                if os.path.lexists(out):
                    os.unlink(out)
                os.symlink(fs.data(ino).decode('latin-1'), out)


if __name__ == '__main__':
    main()
