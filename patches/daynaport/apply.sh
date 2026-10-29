#!/bin/sh
# DaynaPORT networking, applied in place to an A/UX 3.1 disk image (use a copy: DISK is
# changed):
#   patches/daynaport/apply.sh DISK [IP [NETMASK [GATEWAY [DNS]]]]
# DISK gets
#   - dp0 linked into /unix (tools/linkmod.py, as autoconfig would), so the first boot
#     needs no relink and restart; for autoconfig's own relinks later, /etc/boot.d/dayna
#     (bin/dayna, from build.sh) and /etc/master.d/dayna (src/master), and the lines
#     autoconfig keeps for it in /etc/master and /etc/startup,
#   - /etc/startup.d/dayna (src/startup: configures dp0 from /etc/NETADDRS at every
#     boot) and /etc/dpsetup (src/dpsetup: asks for the addresses, writes
#     NETADDRS and resolv.conf),
#   - with IP, the dp0 line of /etc/NETADDRS and the nameserver of /etc/resolv.conf, as
#     dpsetup writes them (default netmask 255.255.255.0, gateway IP's .1, DNS server
#     the gateway): dp0 is up from the first boot. Without IP, run /etc/dpsetup once.
# Check the disk afterwards (tools/ufsput.py DISK PART check; make-disk.sh does).
set -e
if [ $# -lt 1 ] || [ $# -gt 5 ]; then
	echo "usage: $0 DISK [IP [NETMASK [GATEWAY [DNS]]]]" >&2
	exit 1
fi
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
disk=$(abs "$1")
cd "$(dirname "$0")/../.."
p=patches/daynaport
py="python3 -I"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
set -- "$@" "" "" "" ""
ip=$2 mask=${3:-255.255.255.0} gw=$4 dns=$5
root=$($py tools/ufs.py "$disk" find 'Root&Usr' | awk '{ print $1 }')
get() { $py tools/ufs.py "$disk" cat "$root" "$1"; }

get /unix > "$tmp/unix"
$py tools/linkmod.py "$tmp/unix" $p/bin/dayna $p/src/master "$tmp/unix.dp"

# /etc/startup: the line autoconfig writes for a module with a startup.d script, after
# bnet's (lo0 first); without the first-boot relink an earlier test disk left there
get /etc/startup > "$tmp/startup.orig"
awk '
	/^# DaynaPORT test image/ { old = 1 }
	old { if (/\/etc\/reboot$/) old = 0; next }
	/^\/etc\/startup\.d\/dayna / { next }
	{ print }
	/^\/etc\/startup\.d\/bnet / { print "/etc/startup.d/dayna $IFLAG -C 0 -D 0"; done = 1 }
	END { if (!done) print "/etc/startup.d/dayna $IFLAG -C 0 -D 0" }' \
	"$tmp/startup.orig" > "$tmp/startup"
# /etc/master: autoconfig's list of the modules in /unix, ended by "$"
get /etc/master > "$tmp/master.orig"
awk '$1 == "dayna" { next } /^\$$/ { print "dayna - - dayna -1 -1 0" } { print }' \
	"$tmp/master.orig" > "$tmp/master"
grep -q '^dayna ' "$tmp/master" || { echo 'no "$" line in /etc/master' >&2; exit 1; }

if [ -n "$ip" ]; then
	{ get /etc/NETADDRS 2>/dev/null || :; } | grep -v '^dp0[ 	]' > "$tmp/netaddrs" || :
	{ get /etc/resolv.conf 2>/dev/null || :; } | grep -v '^nameserver' > "$tmp/resolv.rest" || :
	awk -v ip="$ip" -v mask="$mask" -v gw="$gw" -v dns="$dns" -v na="$tmp/netaddrs" \
		-v rc="$tmp/resolv.conf" '
	function quad(s, o,   n, i) {
		n = split(s, o, ".")
		if (n != 4) return 0
		for (i = 1; i <= 4; i++)
			if (o[i] !~ /^[0-9]+$/ || o[i] > 255) return 0
		return 1
	}
	function bad(what, s) {
		printf "%s %s is not an address like 192.168.1.50\n", what, s > "/dev/stderr"
		exit 1
	}
	BEGIN {
		if (!quad(ip, a)) bad("IP", ip)
		if (!quad(mask, m)) bad("netmask", mask)
		if (gw == "") gw = a[1] "." a[2] "." a[3] ".1"
		if (dns == "") dns = gw
		if (!quad(gw, g)) bad("gateway", gw)
		if (!quad(dns, d)) bad("DNS server", dns)
		# broadcast: each part of the address with the host bits set
		for (i = 1; i <= 4; i++) {
			b = 256 - m[i]
			bc = bc (i > 1 ? "." : "") (int(a[i] / b) * b + b - 1)
		}
		printf "dp0\t%s %s %s %s\n", ip, bc, mask, gw >> na
		printf "nameserver %s\n", dns > rc
		printf "dp0 %s, netmask %s (broadcast %s), gateway %s, DNS server %s\n",
			ip, mask, bc, gw, dns
	}'
	cat "$tmp/resolv.rest" >> "$tmp/resolv.conf"
fi

put() { $py tools/ufsput.py "$disk" "$root" put "$@" --apply; }
put "$tmp/unix.dp" /unix
put $p/bin/dayna /etc/boot.d/dayna 640 2 2
put $p/src/master /etc/master.d/dayna 644 2 2
put $p/src/startup /etc/startup.d/dayna 750 2 2
put $p/src/dpsetup /etc/dpsetup 750 0 0
put "$tmp/startup" /etc/startup
put "$tmp/master" /etc/master
if [ -n "$ip" ]; then
	put "$tmp/netaddrs" /etc/NETADDRS 644 0 0
	put "$tmp/resolv.conf" /etc/resolv.conf 644 0 0
fi
# what A/UX will read back
$py tools/ufs.py "$disk" cat "$root" /unix | cmp - "$tmp/unix.dp"
echo "$disk: DaynaPORT networking added"
