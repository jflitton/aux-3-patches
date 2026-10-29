#!/bin/sh
# The year 2000 fix for /bin/date (src/date-y2k.txt), applied in place to an A/UX 3.1 disk
# image (use a copy: DISK is changed):
#   patches/date/apply.sh DISK
set -e
if [ $# -ne 1 ]; then
	echo "usage: $0 DISK" >&2
	exit 1
fi
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
disk=$(abs "$1")
cd "$(dirname "$0")/../.."
root=$(python3 -I tools/ufs.py "$disk" find 'Root&Usr' | awk '{ print $1 }')
python3 -I tools/binpatch.py patches/date/src/date-y2k.txt "$disk" "$root" --apply
echo "$disk: year 2000 date fix added"
