#!/bin/sh
# The pkg package manager, applied in place to an A/UX 3.1 disk image (use a copy: DISK is
# changed):
#   patches/pkg/apply.sh DISK
# DISK gets bin/pkg as /usr/local/bin/pkg, and the record pkg keeps of itself as an
# installed package, /usr/local/lib/pkg/installed/pkg (bin/record, then the time, where it
# came from and the file), so pkg can upgrade itself. Directories on the way that aren't
# there yet are made as pkg would make them: mode 755, owned by root. /usr/local/bin goes
# into root's PATH in /.profile and /.login, which give it to every other user already.
# Check the disk afterwards (tools/ufsput.py DISK PART check; make-disk.sh does).
set -e
if [ $# -ne 1 ]; then
	echo "usage: $0 DISK" >&2
	exit 1
fi
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
disk=$(abs "$1")
cd "$(dirname "$0")/../.."
p=patches/pkg
py="python3 -I"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root=$($py tools/ufs.py "$disk" find 'Root&Usr' | awk '{ print $1 }')
ufsput() { $py tools/ufsput.py "$disk" "$root" "$@" --apply; }

for d in /usr/local /usr/local/bin /usr/local/lib /usr/local/lib/pkg \
		/usr/local/lib/pkg/installed; do
	$py tools/ufs.py "$disk" ls "$root" $d > /dev/null 2>&1 || ufsput mkdir $d 755 0 0
done
size=$(wc -c < $p/bin/pkg | tr -d ' ')
sha=$($py -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
	$p/bin/pkg)
{
	cat $p/bin/record
	echo "installed $(date +%s)"
	echo "from aux-3-patches"
	printf 'f\tusr/local/bin/pkg\t755\t0\t0\t%s\t%s\n' "$size" "$sha"
} > "$tmp/record"
ufsput put $p/bin/pkg /usr/local/bin/pkg 755 0 0
ufsput put "$tmp/record" /usr/local/lib/pkg/installed/pkg 644 0 0
# root's PATHs end ":/usr/etc:."; other users' already end ":/usr/etc:/usr/local/bin"
for f in /.profile /.login; do
	$py tools/ufs.py "$disk" cat "$root" $f > "$tmp/dot" 2>/dev/null || continue
	grep -q ':/usr/etc:/usr/local/bin:\."' "$tmp/dot" && continue	# --daynaport did it
	sed 's|:/usr/etc:\."|:/usr/etc:/usr/local/bin:."|' "$tmp/dot" > "$tmp/dot.new"
	if cmp -s "$tmp/dot" "$tmp/dot.new"; then
		echo "$f: no PATH for root to change"
	else
		ufsput put "$tmp/dot.new" $f
	fi
done
# what A/UX will read back
$py tools/ufs.py "$disk" cat "$root" /usr/local/bin/pkg | cmp - $p/bin/pkg
echo "$disk: pkg $(sed -n 's/^version //p' $p/bin/record) added"
