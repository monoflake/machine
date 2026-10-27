#!/usr/bin/env bash
# The rendered table has one scoped drop and leaves every other packet alone.
set -o errexit -o nounset -o pipefail
awk -v tailnet="${2:-tailscale0}" '
function fail() { bad = 1; exit 1 }
{
	sub(/^[ \t]+/, "")
	if ($0 == "table inet machine-ssh {") { tables++; next }
	if ($0 == "chain input {") { chains++; next }
	if ($0 == "type filter hook input priority filter - 10; policy accept;") { bases++; next }
	if ($0 == "}" || $0 == "") next
	if ($0 !~ /^tcp dport [0-9]+ iifname != \{ "[a-zA-Z0-9_.-]+", "[a-zA-Z0-9_.-]+" \} drop$/) fail()
	port = $3
	first = $7
	second = $8
	gsub(/[",]/, "", first)
	gsub(/[",]/, "", second)
	rules++
}
END {
	if (bad || tables != 1 || chains != 1 || bases != 1 || rules != 1) exit 1
	interfaces[1] = tailnet
	interfaces[2] = "lo"
	interfaces[3] = "eth0"
	for (i = 1; i <= 3; i++)
		for (p = 0; p <= 65535; p++) {
			drop = p == port && interfaces[i] != first && interfaces[i] != second
			if (drop != (i == 3 && p == 22)) {
				print "ssh rules: unexpected drop behavior on " interfaces[i] " TCP " p
				exit 1
			}
		}
	print "ssh rules: tailnet and loopback preserved, only public TCP 22 dropped"
}' "$1"
