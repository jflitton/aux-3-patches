#!/usr/bin/env python3
"""Install a pkg package on an A/UX disk image, as pkg itself would (aux-3-pkg's
docs/formats.md), so that pkg can verify, upgrade and remove it later.

  pkgput.py IMAGE PART PACKAGE FROM

The package's files go in with their modes, owned by root, and its directories that
aren't there yet are made; ones already there are left as they are. Its record goes in
/usr/local/lib/pkg/installed/NAME, saying it came from FROM. Its shell lines are added to
/etc/shells, and its boot lines to /etc/inittab, after the line that runs /etc/rc, as pkg
adds them. A file that's already on the disk is refused, as pkg refuses it; so are
symbolic links, which nothing bundled has yet. IMAGE is changed: use a copy.
"""
import gzip, hashlib, io, os, sys, tarfile, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ufs import UFS
from ufsput import Writer

FORMAT = 3                    # the newest package format pkg (0.5) installs
PKGDIR = '/usr/local/lib/pkg'


class Disk:
    def __init__(self, image, part):
        self.image, self.part = image, part

    def exists(self, path):
        try:
            UFS(self.image, self.part).lookup(path)
            return True
        except FileNotFoundError:
            return False

    def cat(self, path):
        fs = UFS(self.image, self.part)
        return fs.data(fs.lookup(path))

    def mkdir(self, path, mode=0o755):
        Writer(self.image, self.part, write=True).mkdir(path, mode, 0, 0)

    def put(self, data, path, mode=None):
        with tempfile.NamedTemporaryFile() as t:
            t.write(data)
            t.flush()
            Writer(self.image, self.part, write=True).put(t.name, path, mode,
                                                          0 if mode is not None else None,
                                                          0 if mode is not None else None)


def meta_lines(text):
    """+PKG's (key, value) lines, in order"""
    out = []
    for line in text.decode('ascii').split('\n'):
        if line and not line.startswith('#'):
            key, _, value = line.partition(' ')
            out.append((key, value))
    return out


def add_shell(disk, shell):
    text = disk.cat('/etc/shells').decode('latin-1') if disk.exists('/etc/shells') else None
    if text is None:
        print("can't add %s to /etc/shells: there's none" % shell)
        return
    lines = text.split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    if shell not in lines:
        disk.put(('\n'.join(lines + [shell]) + '\n').encode('latin-1'), '/etc/shells')
        print('Added %s to /etc/shells' % shell)


def add_boot(disk, name, cmd):
    """The line pkg's etcinittab() adds (aux-3-pkg's src/install.c)"""
    mine = '%s </dev/syscon >/dev/syscon 2>&1\t# pkg %s' % (cmd, name)
    lines = disk.cat('/etc/inittab').decode('latin-1').split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    at, used = None, set()
    for i, line in enumerate(lines):
        f = line.split(':', 3)
        proc = f[3] if len(f) == 4 else None
        if proc == mine:
            return
        if proc is not None and (proc.startswith('/etc/rc ') or proc == '/etc/rc'):
            at = i + 1
        elif at == i and line.startswith('pk') and proc is not None and '\t# pkg ' in proc:
            at = i + 1
        if len(line) > 4 and line[:2] == 'pk' and line[2:4].isdigit() and line[4] == ':':
            used.add(int(line[2:4]))
    free = [n for n in range(100) if n not in used]
    if not free:
        sys.exit('pkgput: no pkNN id left in /etc/inittab')
    lines.insert(len(lines) if at is None else at, 'pk%02d:2:wait:%s' % (free[0], mine))
    disk.put(('\n'.join(lines) + '\n').encode('latin-1'), '/etc/inittab')
    print('Added %s to /etc/inittab, to run at every boot' % cmd)


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__.strip().split('\n\n')[1])
    image, part, package, origin = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    disk = Disk(image, part)
    with open(package, 'rb') as f:
        tar = tarfile.open(fileobj=io.BytesIO(gzip.decompress(f.read())),
                           encoding='mac_roman')
    members = tar.getmembers()
    if not members or members[0].name != '+PKG':
        sys.exit('pkgput: %s: not a package' % package)
    meta = meta_lines(tar.extractfile(members[0]).read())
    keys = dict(meta)
    if int(keys['format']) > FORMAT:
        sys.exit('pkgput: %s is format %s, newer than pkgput knows' % (package,
                                                                       keys['format']))
    name = keys['name']
    record = ['format %s' % keys['format'], 'name %s' % name, 'version %s' % keys['version'],
              'summary %s' % keys['summary']]
    record += ['%s %s' % kv for kv in meta if kv[0] not in
               ('format', 'name', 'version', 'summary')]
    record += ['installed %d' % int(time.time()), 'from %s' % origin]
    if disk.exists('%s/installed/%s' % (PKGDIR, name)):
        sys.exit('pkgput: %s is already installed on the disk' % name)
    for m in members[1:]:
        path = '/' + m.name.rstrip('/')
        if m.isfile() and disk.exists(path):
            sys.exit('pkgput: %s is already on the disk' % path)
        if not (m.isfile() or m.isdir()):
            sys.exit('pkgput: %s: only files and directories, as yet' % path)

    for m in members[1:]:
        path = '/' + m.name.rstrip('/')
        if m.isdir():
            if not disk.exists(path):
                disk.mkdir(path, m.mode & 0o7777)
                record.append('d\t%s' % path[1:])
        else:
            data = tar.extractfile(m).read()
            disk.put(data, path, m.mode & 0o7777)
            record.append('f\t%s\t%o\t0\t0\t%d\t%s' % (path[1:], m.mode & 0o7777, len(data),
                                                     hashlib.sha256(data).hexdigest()))
    d = ''
    for part_ in PKGDIR.split('/')[1:] + ['installed']:
        d += '/' + part_
        if not disk.exists(d):
            disk.mkdir(d)
    disk.put(('\n'.join(record) + '\n').encode('ascii'), '%s/installed/%s' % (PKGDIR, name),
             0o644)
    for key, value in meta:
        if key == 'shell':
            add_shell(disk, value)
        elif key == 'boot':
            add_boot(disk, name, value)
    print('Installed %s %s' % (name, keys['version']))


if __name__ == '__main__':
    main()
