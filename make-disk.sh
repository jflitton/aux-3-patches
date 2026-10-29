#!/bin/sh
# Make a patched copy of an A/UX 3 disk image, with the patches you choose. Instructions:
# README.md.

usage() {
	cat <<'EOF'
Usage: ./make-disk.sh AUX-IMAGE NEW-DISK PATCHES... [network settings]

  AUX-IMAGE  an A/UX 3.1 disk image: AUX_3_1_1GB_Use_In_Shoebill.zip (made for
             the Shoebill emulator), the AUX_3_1_1GB.dsk inside it, or your own.
             It is only read, never changed.
  NEW-DISK   the patched copy to make, e.g. ~/Desktop/HD0_AUX.hda

Patches (choose one or more):
  --memcjr ENABLER     MEMCjr support, for the Quadra 605. ENABLER is System
                       Enabler 065 as you downloaded it,
                       e.g. System_Enabler_065_12-sea.bin
  --daynaport          DaynaPORT networking, for a BlueSCSI or ZuluSCSI with Wi-Fi
  --date               the date command, fixed for years after 1999

Each patch is described in patches/NAME/README.md.

Network settings for --daynaport (all optional; leave them out and run
/etc/dpsetup on the Mac once instead):
  --ip ADDRESS       the Mac's IP address, e.g. 192.168.1.50
  --netmask MASK     your network's netmask (normally 255.255.255.0, the default)
  --gateway ADDRESS  your router (default: the IP address with .1 at the end)
  --dns ADDRESS      your DNS server (default: the router)

Example, a Quadra 605 disk with every patch:
  ./make-disk.sh ~/Downloads/AUX_3_1_1GB_Use_In_Shoebill.zip ~/Desktop/HD0_AUX.hda \
      --memcjr ~/Downloads/System_Enabler_065_12-sea.bin --daynaport --date \
      --ip 192.168.1.50
EOF
}

say() { printf '%s\n' "$@"; }
die() { say "" "$*" >&2; exit 1; }

# --- the patches -------------------------------------------------------------------
#
# A patch NAME lives in patches/NAME, and has an option (in the argument loop below) and:
#   NEEDS_NAME    programs it uses, as "program:Homebrew-package ..."
#   title_NAME    what it is, for the progress lines
#   check_NAME    run on the A/UX disk before anything is written; dies if the patch
#                 can't go on it
#   apply_NAME    patches the new disk ($out) in place; its output goes to the log
# PATCHES lists them in the order they are applied.
PATCHES="memcjr date daynaport"

# the A/UX 3.1 kernel: the MEMCjr kernel patch matches the core of every 3.1 kernel
# (whatever it is configured for, and whether it has the patch already) and no other
is_aux31() {
	python3 -I tools/binpatch.py patches/memcjr/bin/kernel-605.txt "$src" "$root" > /dev/null 2>&1
}

NEEDS_memcjr="hmount:hfsutils unar:unar"
title_memcjr() { say "MEMCjr support (Quadra 605)"; }
check_memcjr() {
	[ -f "$enabler" ] || die "Can't find System Enabler 065: $enabler"
	lsar "$enabler" 2>/dev/null | grep -q 065 ||
		die "$(basename "$enabler") doesn't look like System Enabler 065. Use the file as you
downloaded it (for example System_Enabler_065_12-sea.bin)."
	is_aux31 || die "$name isn't an A/UX 3.1 disk: its kernel is different."
}
apply_memcjr() { run sh patches/memcjr/apply.sh "$out" "$enabler"; }

NEEDS_date=
title_date() { say "the year 2000 fix for date"; }
check_date() {
	python3 -I tools/binpatch.py patches/date/src/date-y2k.txt "$src" "$root" > /dev/null 2>&1 ||
		die "$name's date command isn't the A/UX 3.1 one this patch fixes."
}
apply_date() { run sh patches/date/apply.sh "$out"; }

NEEDS_daynaport=
title_daynaport() {
	if [ -n "$ip" ]; then say "DaynaPORT networking, set to IP address $ip"
	else say "DaynaPORT networking"; fi
}
check_daynaport() {
	is_aux31 || die "$name isn't an A/UX 3.1 disk: its kernel is different."
	if python3 -I tools/ufs.py "$src" cat "$root" /etc/boot.d/dayna > /dev/null 2>&1; then
		die "$name already has the DaynaPORT network driver."
	fi
}
apply_daynaport() {
	# empty settings take the defaults
	if [ -n "$ip" ]; then set -- "$ip" "$mask" "$gw" "$dns"; else set --; fi
	run sh patches/daynaport/apply.sh "$out" "$@"
}

# --- what was asked for ------------------------------------------------------------

chosen= aux= out= enabler= ip= mask= gw= dns= n=0
choose() { case " $chosen " in *" $1 "*) ;; *) chosen="$chosen $1" ;; esac; }
want() { case " $chosen " in *" $1 "*) return 0 ;; esac; return 1; }
while [ $# -gt 0 ]; do
	case $1 in
	-h|--help|help)
		usage; exit 0 ;;
	--memcjr)
		[ $# -ge 2 ] || die "--memcjr needs System Enabler 065, e.g.
--memcjr ~/Downloads/System_Enabler_065_12-sea.bin"
		choose memcjr; enabler=$2; shift 2; continue ;;
	--daynaport)
		choose daynaport; shift; continue ;;
	--date)
		choose date; shift; continue ;;
	--ip|--netmask|--gateway|--dns)
		[ $# -ge 2 ] || die "$1 needs a value, e.g. $1 192.168.1.50"
		case $1 in
		--ip) ip=$2 ;; --netmask) mask=$2 ;; --gateway) gw=$2 ;; --dns) dns=$2 ;;
		esac
		shift 2; continue ;;
	-*)
		usage; die "Unknown option: $1" ;;
	esac
	n=$((n + 1))
	case $n in 1) aux=$1 ;; 2) out=$1 ;; *) usage; die "Too many files: $1" ;; esac
	shift
done
if [ $n -lt 2 ]; then usage; exit 1; fi
[ -n "$chosen" ] || die "Choose at least one patch: --memcjr ENABLER, --daynaport or --date.
(./make-disk.sh --help lists them.)"

isaddr() {
	say "$1" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' &&
		say "$1" | tr . '\n' | awk '$1 > 255 { exit 1 }'
}
if [ -n "$ip$mask$gw$dns" ] && ! want daynaport; then
	die "--ip, --netmask, --gateway and --dns are settings for --daynaport."
fi
if [ -z "$ip" ] && [ -n "$mask$gw$dns" ]; then
	die "--netmask, --gateway and --dns go with --ip (the Mac's own address)."
fi
for a in "IP address:$ip" "netmask:$mask" "gateway:$gw" "DNS server:$dns"; do
	v=${a#*:}
	if [ -n "$v" ] && ! isaddr "$v"; then
		die "The ${a%%:*} '$v' isn't an address like 192.168.1.50."
	fi
done

# the steps below run from this script's folder, so make the paths absolute first
start=$(pwd)
abs() { case $1 in /*) say "$1" ;; *) say "$start/$1" ;; esac; }
aux=$(abs "$aux") out=$(abs "$out")
[ -n "$enabler" ] && enabler=$(abs "$enabler")
cd "$(dirname "$0")" || exit 1

# --- the tools this needs ----------------------------------------------------------

# Homebrew's programs, in case this Terminal window doesn't know about them yet
PATH=$PATH:/opt/homebrew/bin:/usr/local/bin
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
	die "Python 3 isn't ready on this Mac. Install Homebrew (https://brew.sh), which also
installs Apple's command line tools and Python 3, then run this again."
fi
missing=
for p in $chosen; do
	eval "needs=\$NEEDS_$p"
	for need in $needs; do
		command -v "${need%%:*}" > /dev/null ||
			case " $missing " in *" ${need#*:} "*) ;; *) missing="$missing ${need#*:}" ;; esac
	done
done
if [ -n "$missing" ]; then
	die "Some tools are missing. Install them with Homebrew (https://brew.sh):

    brew install$missing

then run this again."
fi

# --- the files ---------------------------------------------------------------------

[ -f "$aux" ] || die "Can't find the A/UX disk image: $aux"
[ -e "$out" ] && die "$out already exists. Choose another name, or move the old one away first."
outdir=$(dirname "$out")
[ -d "$outdir" ] && [ -w "$outdir" ] || die "Can't write a new file in $outdir"

tmp=$(mktemp -d) || exit 1
log=$tmp/log
made=
# a half-made disk is removed, whatever stopped it
cleanup() { [ -n "$made" ] && rm -f "$out"; rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 1' INT TERM
fail() {
	cp "$log" "$out.log" 2>/dev/null
	say "" "That didn't work: $1" "" "The last lines of the log:" >&2
	tail -8 "$log" | sed 's/^/    /' >&2
	say "" "The whole log is in $out.log" >&2
	exit 1
}
run() { "$@" >> "$log" 2>&1; }

name=$(basename "$aux")
say "Making a patched copy of $name (this takes a few minutes)."
# src: the disk the checks read. A zip is unpacked straight into the new disk.
case $aux in
*.zip|*.ZIP)
	dsk=$(unzip -Z1 "$aux" 2>/dev/null | grep -v '^__MACOSX/' | grep -i '\.dsk$' | head -1)
	[ -n "$dsk" ] || die "There's no .dsk disk image inside $name"
	say "  Unpacking $name ..."
	made=1
	unzip -p "$aux" "$dsk" > "$out" 2>> "$log" || fail "couldn't unpack $name."
	name=$(basename "$dsk") src=$out
	;;
*)
	src=$aux
	;;
esac
root=$(python3 -I tools/ufs.py "$src" find 'Root&Usr' 2>/dev/null | awk '{ print $1 }')
[ -n "$root" ] || die "$name doesn't look like an A/UX disk image."
for p in $PATCHES; do
	want $p && check_$p
done

# --- the work ----------------------------------------------------------------------

if [ "$src" != "$out" ]; then
	say "  Copying $name ..."
	made=1
	run cp -c "$aux" "$out" || run cp "$aux" "$out" || fail "couldn't copy $name."
fi
chmod u+w "$out"
added=
for p in $PATCHES; do
	want $p || continue
	say "  Adding $(title_$p) ..."
	apply_$p || fail "couldn't add $(title_$p)."
	added="$added${added:+, }$(title_$p | sed 's/, set to.*//')"
done
say "  Checking the new disk ..."
run python3 -I tools/ufsput.py "$out" "$root" check || fail "the new disk didn't pass its check."
made=

say "" "Done! Your new disk image is $out" "It has: $added."
if [ -n "$ip" ]; then
	sed -n 's/^dp0 \(.*\) (broadcast [^)]*)\(.*\)/Network: IP address \1\2/p' "$log"
fi
