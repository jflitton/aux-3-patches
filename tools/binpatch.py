#!/usr/bin/env python3
"""Apply byte patches, written against COFF symbols, to A/UX files.

  binpatch.py SPEC FILE [--apply]            patch a plain file (e.g. an extracted copy)
  binpatch.py SPEC IMAGE PART [--apply]      patch the files inside UFS partition PART of
                                             a disk image (throwaway clones only)
  binpatch.py --sum FILE AT LENGTH           print the check value of LENGTH bytes at AT

Without --apply nothing is written: every site is only verified and reported, so the
originals (which may be writable) are safe from a slip. Original bytes are replaced,
already-patched bytes are left alone, anything else is an error and nothing is written.

SPEC format (';' starts a comment, hex bytes may be spaced freely):

  file /unix /etc/config.d/newunix     target paths on the A/UX root; the sites below
                                       apply to each
  at GetLowFromKernel+0x3a             COFF symbol + offset (or a plain 0xVADDR)
  check 3f9c0e1a2b4d5e6f               first 16 hex digits of the SHA-256 of the
                                       original bytes (as many as 'new' has), so specs
                                       carry no Apple bytes
  new 0c 00 00 58 67 ca 4e 71          replacement (several lines append)
"""
import hashlib, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from coff import Coff  # noqa: E402
from ufs import UFS  # noqa: E402


def checksum(data):
    return hashlib.sha256(data).hexdigest()[:16]


def parse(path):
    files, cur, site = [], None, None
    for n, line in enumerate(open(path), 1):
        words = line.split(';')[0].split()
        if not words:
            continue
        key, rest = words[0], words[1:]
        if key == 'file':
            cur = dict(paths=rest, sites=[])
            files.append(cur)
        elif key == 'at':
            site = dict(at=rest[0], check=None, new=b'', line=n)
            cur['sites'].append(site)
        elif key == 'check':
            site['check'] = rest[0]
        elif key == 'new':
            site['new'] += bytes.fromhex(''.join(rest))
        else:
            raise SystemExit('%s:%d: unknown keyword %r' % (path, n, key))
    for f in files:
        for s in f['sites']:
            if not s['check'] or not s['new']:
                raise SystemExit('%s:%d: site needs check and new' % (path, s['line']))
    return files


def file_offset(coff, at):
    name, _, off = at.partition('+')
    if name.startswith('0x'):
        vaddr = int(name, 16)
    else:
        vals = {s['value'] & 0xffffffff for s in coff.symbols
                if s['name'] == name and s['scnum'] > 0}
        if len(vals) != 1:
            raise SystemExit('symbol %s: %d definitions' % (name, len(vals)))
        vaddr = vals.pop()
    vaddr += int(off, 0) if off else 0
    for s in coff.sections:
        if s['scnptr'] and s['vaddr'] <= vaddr < s['vaddr'] + s['size']:
            return s['scnptr'] + vaddr - s['vaddr']
    raise SystemExit('%s (%#x) is not in a loaded section' % (at, vaddr))


def patch(sites, data, label, write):
    """Verify every site in data; then call write(offset, bytes) for those to patch
    (write None: report only)."""
    coff, todo = Coff(data), []
    for s in sites:
        off = file_offset(coff, s['at'])
        cur = data[off:off + len(s['new'])]
        if cur == s['new']:
            state = 'already patched'
        elif checksum(cur) == s['check']:
            state = 'patching' if write else 'would patch'
            todo.append((off, s['new']))
        else:
            raise SystemExit('%s %s: unexpected bytes (check %s, want %s)' % (
                label, s['at'], checksum(cur), s['check']))
        print('%s %s (file +%#x, %d bytes): %s' % (label, s['at'], off, len(s['new']), state))
    for off, new in todo if write else ():
        write(off, new)


def main():
    if sys.argv[1] == '--sum':
        data = open(sys.argv[2], 'rb').read()
        off = file_offset(Coff(data), sys.argv[3])
        print(checksum(data[off:off + int(sys.argv[4], 0)]))
        return
    args = [a for a in sys.argv[1:] if a != '--apply']
    apply = '--apply' in sys.argv
    spec, target = parse(args[0]), args[1]
    out = open(target, 'r+b') if apply else None
    if len(args) == 2:
        if len(spec) != 1:
            raise SystemExit('a plain FILE target takes a spec with one file line')

        def write(off, new):
            out.seek(off)
            out.write(new)
        patch(spec[0]['sites'], open(target, 'rb').read(), target, apply and write)
        return
    fs = UFS(target, int(args[2]))
    for f in spec:
        for path in f['paths']:
            ino = fs.lookup(path)

            def write(off, new, ino=ino):
                for i, b in enumerate(new):  # file blocks need not be contiguous
                    where = fs.image_offset(ino, off + i)
                    if where is None:
                        raise SystemExit('%s: +%#x is in a hole' % (path, off + i))
                    out.seek(where)
                    out.write(bytes([b]))
            patch(f['sites'], fs.data(ino), path, apply and write)


if __name__ == '__main__':
    main()
