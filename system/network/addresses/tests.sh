#!/usr/bin/env bash
# Both sources and the host interfaces are faked before discovery runs.
set -o errexit -o nounset -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
if [ -z "${MACHINE_ADDRESSES_TOOLS:-}" ]; then
	t=$(realpath "$(mktemp -d)")
	trap 'rm -rf "$t"' EXIT
	cp "$here/../../../flake.nix" "$here/../../../flake.lock" "$t/"
	nix shell --inputs-from "path:$t" nixpkgs#jq nixpkgs#coreutils \
		-c env MACHINE_ADDRESSES_TOOLS=1 ${TMPDIR:+TMPDIR="$TMPDIR"} bash "$0"
	exit
fi
tmp=$(realpath "$(mktemp -d)")
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
export PATH=$tmp/bin:$PATH FAKE_ADDRESSES=$tmp MACHINE_ADDRESSES_STATE=$tmp/state/addresses.json
export REAL_MV
REAL_MV=$(command -v mv)
cat >"$tmp/bin/tailscale" <<'FAKE'
#!/usr/bin/env bash
[ "$*" = 'netcheck --format=json' ] || exit 2
round=$(cat "$FAKE_ADDRESSES/round")
echo netcheck >>"$FAKE_ADDRESSES/calls"
[ ! -f "$FAKE_ADDRESSES/$round/netcheck-fail" ] || exit 1
cat "$FAKE_ADDRESSES/$round/netcheck"
FAKE
cat >"$tmp/bin/curl" <<'FAKE'
#!/usr/bin/env bash
[ "${*:1:7}" = '--disable '"$2"' --noproxy * --fail --silent --show-error' ] || exit 2
[ "${*:8:4}" = '--connect-timeout 5 --max-time 10' ] || exit 2
case "$2 ${12}" in
	'-4 https://1.1.1.1/cdn-cgi/trace') ;;
	'-6 https://[2606:4700:4700::1111]/cdn-cgi/trace') ;;
	*) exit 2 ;;
esac
family=v4
[ "$2" = -4 ] || family=v6
round=$(cat "$FAKE_ADDRESSES/round")
echo "trace $family" >>"$FAKE_ADDRESSES/calls"
[ ! -f "$FAKE_ADDRESSES/$round/$family-fail" ] || exit 1
cat "$FAKE_ADDRESSES/$round/$family"
FAKE
cat >"$tmp/bin/ip" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == '-j -'*' address show scope global' ]] || exit 2
family=v4
[ "$2" = -4 ] || family=v6
[ ! -f "$FAKE_ADDRESSES/host-fail" ] || exit 1
if [ -f "$FAKE_ADDRESSES/no-$family" ]; then
	echo '[]'
else
	echo '[{"addr_info":[{"scope":"global"}]}]'
fi
FAKE
cat >"$tmp/bin/sleep" <<'FAKE'
#!/usr/bin/env bash
[ "$*" = 60 ] || exit 2
echo sleep >>"$FAKE_ADDRESSES/calls"
if [ -f "$FAKE_ADDRESSES/before" ]; then
	cmp "$FAKE_ADDRESSES/before" "$MACHINE_ADDRESSES_STATE" || exit 2
else
	[ ! -f "$MACHINE_ADDRESSES_STATE" ] || exit 2
fi
echo 2 >"$FAKE_ADDRESSES/round"
FAKE
cat >"$tmp/bin/mv" <<'FAKE'
#!/usr/bin/env bash
if [ -f "$FAKE_ADDRESSES/readonly" ]; then
	parent=${MACHINE_ADDRESSES_STATE%/*}
	chmod 0500 "$parent"
	"$REAL_MV" "$@"
	status=$?
	cmp "$FAKE_ADDRESSES/before" "$MACHINE_ADDRESSES_STATE" || status=2
	chmod 0700 "$parent"
	exit "$status"
fi
exec "$REAL_MV" "$@"
FAKE
chmod +x "$tmp/bin/"*
checks=0

fresh() {
	rm -f "$tmp/state/"* "$tmp/before" "$tmp/readonly" "$tmp/no-v4" "$tmp/no-v6" "$tmp/host-fail"
	rm -rf "$tmp/1" "$tmp/2"
	mkdir "$tmp/1" "$tmp/2"
	for round in 1 2; do
		replies "$round" 192.0.2.10 2001:db8::10
	done
}
replies() {
	local round=$1 v4=$2 v6=$3 endpoint4='' endpoint6=''
	[ -z "$v4" ] || endpoint4=$v4:1234
	[ -z "$v6" ] || endpoint6=[$v6]:5678
	jq -nc --arg a "$endpoint4" --arg b "$endpoint6" '{GlobalV4:$a,GlobalV6:$b}' \
		>"$tmp/$round/netcheck"
	printf 'fl=test\nip=%s\n' "$v4" >"$tmp/$round/v4"
	printf 'ip=%s\n' "$v6" >"$tmp/$round/v6"
}
run() {
	local want=$1 got=0
	echo 1 >"$tmp/round"
	: >"$tmp/calls"
	if [ -f "$MACHINE_ADDRESSES_STATE" ]; then
		cp "$MACHINE_ADDRESSES_STATE" "$tmp/before"
	fi
	bash -o errexit -o nounset -o pipefail "$here/discover.sh" "$here/parse.jq" \
		>"$tmp/said" 2>&1 || got=$?
	if [ "$got" != "$want" ]; then
		cat "$tmp/said" >&2
		echo "addresses expected exit $want, got $got" >&2
		exit 1
	fi
	checks=$((checks + 1))
	jq -e 'keys == ["v4", "v6"] and all(.[];
		keys == ["address", "checked_at", "confirmed_at", "reason", "state"]
		and (.checked_at | test("^[0-9]{4}(-[0-9]{2}){2}T[0-9]{2}(:[0-9]{2}){2}Z$"))
		and (.confirmed_at == null or (.confirmed_at |
			test("^[0-9]{4}(-[0-9]{2}){2}T[0-9]{2}(:[0-9]{2}){2}Z$"))))' \
		"$MACHINE_ADDRESSES_STATE" >/dev/null || {
		cat "$MACHINE_ADDRESSES_STATE" "$tmp/said" >&2
		exit 1
	}
}
holds() {
	if ! jq -e "$1" "$MACHINE_ADDRESSES_STATE" >/dev/null; then
		cat "$MACHINE_ADDRESSES_STATE" >&2
		echo "addresses assertion failed $1" >&2
		exit 1
	fi
}
waited() { [ "$(grep -c '^sleep$' "$tmp/calls" || true)" = "$1" ]; }
kept() {
	jq -e --slurpfile before "$tmp/before" --arg f "$1" \
		'.[$f].address == $before[0][$f].address
		and .[$f].confirmed_at == $before[0][$f].confirmed_at' "$MACHINE_ADDRESSES_STATE" >/dev/null
}

fresh
run 0
holds '.v4.state == "confirmed" and .v4.address == "192.0.2.10"
	and .v6.state == "confirmed" and .v6.address == "2001:db8::10"'
waited 1
echo 'addresses both families agree after the initial confirmation'
run 0
waited 0
echo 'addresses an unchanged address needs no second check'

replies 1 198.51.100.20 2001:db8::20
replies 2 198.51.100.20 2001:db8::20
run 0
holds '.v4.address == "198.51.100.20" and .v6.address == "2001:db8::20"
	and all(.[]; .state == "confirmed")'
waited 1
echo 'addresses a change waits with the old file intact and then confirms'

replies 1 203.0.113.30 2001:db8::30
replies 2 192.0.2.40 2001:db8::40
run 0
holds 'all(.[]; .state == "disputed" and .reason == "second check disagrees with first candidate")'
kept v4
kept v6
echo 'addresses a different second candidate keeps both last confirmed addresses'

replies 1 198.51.100.20 2001:db8::20
printf 'ip=203.0.113.30\n' >"$tmp/1/v4"
run 0
holds '.v4.state == "disputed" and .v4.reason == "netcheck and trace disagree"
	and .v6.state == "confirmed"'
kept v4
waited 0
echo 'addresses a source disagreement leaves the other family independent'

touch "$tmp/1/v4-fail"
run 0
holds '.v4.state == "unknown" and .v4.reason == "trace unavailable or unparseable"
	and .v6.state == "confirmed"'
kept v4
echo 'addresses an unreachable trace keeps the last address across a process restart'
rm "$tmp/1/v4-fail"
touch "$tmp/1/netcheck-fail"
run 0
holds 'all(.[]; .state == "unknown")'
kept v4
kept v6
rm "$tmp/1/netcheck-fail"
echo 'addresses an unreachable netcheck keeps both last confirmed addresses'

touch "$tmp/no-v6"
run 0
holds '.v6.state == "none" and .v6.reason == "no host address with global scope"'
kept v6
if grep -q '^trace v6$' "$tmp/calls"; then exit 1; fi
echo 'addresses a missing host family is none and skips its trace'
rm "$tmp/no-v6"
replies 1 '' ''
run 0
holds 'all(.[]; .state == "none" and .reason == "both sources explicitly report no address")'
kept v4
kept v6
echo 'addresses explicit absence from both sources is none'

fresh
printf 'not json\n' >"$tmp/1/netcheck"
run 0
holds 'all(.[]; .state == "unknown" and .address == null and .confirmed_at == null)'
waited 0
echo 'addresses malformed replies are unknown without inventing an address'
replies 1 192.0.2.10 2001:db8::10
printf 'ip=2001:db8:0:0:0:0:0:10\r\n' >"$tmp/1/v6"
run 0
holds 'all(.[]; .state == "confirmed")'
echo 'addresses equivalent IPv6 spellings and trace carriage returns agree'

replies 1 203.0.113.30 2001:db8::30
replies 2 203.0.113.30 2001:db8::30
touch "$tmp/2/v4-fail"
printf 'ip=2001:db8::40\n' >"$tmp/2/v6"
run 0
holds '.v4.state == "unknown" and (.v4.reason | startswith("second check "))
	and .v6.state == "disputed"'
kept v4
kept v6
echo 'addresses second check failures keep each last confirmed address'
rm "$tmp/2/v4-fail"

touch "$tmp/host-fail"
run 0
holds 'all(.[]; .state == "unknown" and .reason == "host addresses unavailable or unparseable")'
waited 0
rm "$tmp/host-fail"
echo 'addresses a failed host query is unknown rather than absence'

touch "$tmp/readonly"
run 1
cmp "$tmp/before" "$MACHINE_ADDRESSES_STATE"
[ "$(find "$tmp/state" -type f | wc -l | tr -d ' ')" = 1 ]
echo 'addresses a read only rename fails with the old file whole and no partial file'
echo "addresses $checks service runs passed with their expected exit statuses"

nix eval --impure --json --file "$here/eval-test.nix" --apply 'f: f {}' >"$tmp/evaluated"
echo "addresses $(jq '.tests | length' "$tmp/evaluated") evaluation checks passed"
