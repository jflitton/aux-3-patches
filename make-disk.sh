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
  --enabler ENABLER    support for a Mac that A/UX 3.1 doesn't know. ENABLER is
                       the System Enabler your Mac needs, as you downloaded it,
                       and it picks the patch:
                         065 (e.g. System_Enabler_065_12-sea.bin): the Quadra
                             605 with a full 68040 (the LC 475 and Performa
                             475/476 untested)
                         003 version 1.1 (e.g. System_Enabler_003_1.1.sea.bin):
                             the LC III and LC III+, and the Performa
                             450/460/466/467, with an FPU
                       One enabler per disk: a disk is for one of these Macs.
  --daynaport          DaynaPORT networking, for a BlueSCSI or ZuluSCSI with Wi-Fi
  --date               the date command, fixed for years after 1999
  --pkg                the pkg package manager, which installs software from package
                       files or over the network

Each patch is described in patches/NAME/README.md; for --enabler, NAME is q605
(System Enabler 065) or lc3 (003).

Network settings for --daynaport (all optional; leave them out and the Mac gets
its address by DHCP, from your router):
  --ip ADDRESS       the Mac's IP address, e.g. 192.168.1.50
  --netmask MASK     your network's netmask (normally 255.255.255.0, the default)
  --gateway ADDRESS  your router (default: the IP address with .1 at the end)
  --dns ADDRESS      your DNS server (default: the router)

Example, a Quadra 605 disk with every patch:
  ./make-disk.sh ~/Downloads/AUX_3_1_1GB_Use_In_Shoebill.zip ~/Desktop/HD0_AUX.hda \
      --enabler ~/Downloads/System_Enabler_065_12-sea.bin --daynaport --date --pkg \
      --ip 192.168.1.50

An LC III disk:
  ./make-disk.sh ~/Downloads/AUX_3_1_1GB_Use_In_Shoebill.zip ~/Desktop/HD0_AUX.hda \
      --enabler ~/Downloads/System_Enabler_003_1.1.sea.bin --date
EOF
}

say() { printf '%s\n' "$@"; }
die() { say "" "$*" >&2; exit 1; }

# --- the patches -------------------------------------------------------------------
#
# A patch NAME lives in patches/NAME, and has an option (in the argument loop below) and:
#   NEEDS_NAME    programs it uses, as "program:package ..." (the package's name in
#                 Homebrew, apt and dnf alike)
#   title_NAME    what it is, for the progress lines
#   check_NAME    run on the A/UX disk before anything is written; dies if the patch
#                 can't go on it
#   apply_NAME    patches the new disk ($out) in place; its output goes to the log
# PATCHES lists them in the order they are applied.
PATCHES="mac date daynaport pkg"

# The Macs A/UX 3.1 doesn't know come in groups, one patch each (patches/GROUP, with
# apply.sh DISK ENABLER). The System Enabler those Macs need for System 7.1 picks the
# group: tools/enabler.py reads the Macs the enabler lists, by BoxFlag (the Gestalt machine
# type minus 6), and the group is the one with any of them. Each group has
#   BOXFLAGS_GROUP  its Macs' BoxFlags, in hex
#   TITLE_GROUP     what it is, for the progress lines
# (MACS, not GROUPS: bash, which is sh on macOS, has a read-only GROUPS, and assigning it
# ends the script without a word.)
MACS="q605 lc3"
BOXFLAGS_q605="53 54 58 59"	# LC/Performa 475, Quadra 605, each at 25 and 33 MHz
TITLE_q605="Quadra 605 support (LC/Performa 475 untested)"
BOXFLAGS_lc3="15 38"		# LC III and Performa 450; LC III+ and Performa 460-467
TITLE_lc3="LC III and LC III+ support"

# kernel_ok SPEC: the kernel patch SPEC applies to the disk's kernel, or is on it already
kernel_ok() { python3 -I tools/binpatch.py "$1" "$src" "$root" > /dev/null 2>&1; }
# the A/UX 3.1 kernel: each group's kernel patch matches the core of every 3.1 kernel
# (whatever it is configured for, and whether it has that patch already) and no other
is_aux31() {
	for g in $MACS; do kernel_ok patches/$g/bin/kernel.txt && return 0; done
	return 1
}

# mac: --enabler, the patch for the group of Macs the enabler is for ($group, set by
# check_mac)
NEEDS_mac="hmount:hfsutils unar:unar"
title_mac() { eval "say \"\$TITLE_$group\""; }
check_mac() {
	[ -f "$enabler" ] || die "Can't find the System Enabler: $enabler"
	rm -rf "$tmp/enabler"
	unar -q -k visible -o "$tmp/enabler" "$enabler" > /dev/null 2>&1 &&
		set -- "$tmp"/enabler/* && [ $# -eq 1 ] &&
		info=$(python3 -I tools/enabler.py "$1" 2> /dev/null) ||
		die "$(basename "$enabler") doesn't look like a System Enabler. Use the file as you
downloaded it (for example System_Enabler_065_12-sea.bin)."
	number=${info%% *} group=
	for g in $MACS; do
		eval "flags=\$BOXFLAGS_$g"
		for f in $flags; do
			case " ${info#* } " in *" $f "*) group=$g ;; esac
		done
	done
	[ -n "$group" ] || die "System Enabler $number is for Macs these patches don't support (yet).
./make-disk.sh --help lists the enablers they take."
	# the old options, --memcjr (065) and --sonora (003), still work, for their own Macs
	[ -z "$expect" ] || [ "$group" = "$expect" ] ||
		die "$option doesn't take System Enabler $number. Give it with --enabler, which picks
the patch for the Macs the enabler is for."
	is_aux31 || die "$name isn't an A/UX 3.1 disk: its kernel is different."
	kernel_ok patches/$group/bin/kernel.txt ||
		die "$name has the patch for other Macs already. Start from an unpatched disk."
}
apply_mac() { run sh patches/$group/apply.sh "$out" "$enabler"; }

NEEDS_date=
title_date() { say "the year 2000 fix for date"; }
check_date() {
	python3 -I tools/binpatch.py patches/date/src/date-y2k.txt "$src" "$root" > /dev/null 2>&1 ||
		die "$name's date command isn't the A/UX 3.1 one this patch fixes."
}
apply_date() { run sh patches/date/apply.sh "$out"; }

NEEDS_daynaport="cmp:diffutils"
title_daynaport() {
	if [ -n "$ip" ]; then say "DaynaPORT networking, set to IP address $ip"
	else say "DaynaPORT networking, by DHCP"; fi
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

NEEDS_pkg="cmp:diffutils"
title_pkg() { say "the pkg package manager"; }
check_pkg() {
	if python3 -I tools/ufs.py "$src" cat "$root" /usr/local/bin/pkg > /dev/null 2>&1; then
		die "$name already has pkg."
	fi
}
apply_pkg() { run sh patches/pkg/apply.sh "$out"; }

# --- what was asked for ------------------------------------------------------------

chosen= aux= out= enabler= expect= option= group= ip= mask= gw= dns= n=0
choose() { case " $chosen " in *" $1 "*) ;; *) chosen="$chosen $1" ;; esac; }
want() { case " $chosen " in *" $1 "*) return 0 ;; esac; return 1; }
while [ $# -gt 0 ]; do
	case $1 in
	-h|--help|help)
		usage; exit 0 ;;
	--enabler|--memcjr|--sonora)
		[ $# -ge 2 ] || die "$1 needs the System Enabler your Mac needs, e.g.
$1 ~/Downloads/System_Enabler_065_12-sea.bin"
		[ -z "$enabler" ] || die "Give one System Enabler: a disk is for one group of Macs."
		case $1 in --memcjr) expect=q605 ;; --sonora) expect=lc3 ;; esac
		choose mac; option=$1 enabler=$2; shift 2; continue ;;
	--daynaport)
		choose daynaport; shift; continue ;;
	--date)
		choose date; shift; continue ;;
	--pkg)
		choose pkg; shift; continue ;;
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
[ -n "$chosen" ] || die "Choose at least one patch: --enabler ENABLER, --daynaport, --date
or --pkg. (./make-disk.sh --help lists them.)"

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
mac=; [ "$(uname)" = Darwin ] && mac=1
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
	[ -n "$mac" ] || die "This needs Python 3.9 or later."
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
[ -n "$missing" ] && [ -z "$mac" ] && die "This needs these packages installed:$missing"
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
	# Shoebill's zips hold a .dsk (A/UX 3.1) or a .iso (A/UX 3.0)
	dsk=$(unzip -Z1 "$aux" 2>/dev/null | grep -v '^__MACOSX/' |
		grep -Ei '\.(dsk|iso|img|hda|hd)$' | head -1)
	[ -n "$dsk" ] || die "There's no disk image inside $name"
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
# another release is named plainly; a 3.1 disk still has to pass its patches' checks
release=$(python3 -I tools/ufs.py "$src" cat "$root" /etc/RELEASE_ID 2>/dev/null |
	sed -n 's|.*A/UX \([0-9][0-9.]*\).*|\1|p' | head -1)
case $release in
''|3.1|3.1.*) ;;
*) die "$name is A/UX $release, but these patches are for A/UX 3.1. Start from an A/UX 3.1
disk image, such as AUX_3_1_1GB_Use_In_Shoebill.zip." ;;
esac
for p in $PATCHES; do
	want $p && check_$p
done

# --- the work ----------------------------------------------------------------------

if [ "$src" != "$out" ]; then
	say "  Copying $name ..."
	made=1
	# a clone on APFS (cp -c, macOS only) or Btrfs (GNU cp's default), else a copy
	cp -c "$aux" "$out" 2>/dev/null || run cp "$aux" "$out" || fail "couldn't copy $name."
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
