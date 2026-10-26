#!/usr/bin/env bash
# Tailscale and nft are faked on PATH while the production script keeps its state in a scratch run.
set -o errexit -o nounset -o pipefail
closer=$2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
export PATH=$tmp/bin:$PATH MACHINE_SSH_STATE=$tmp/run FAKE_SSH=$tmp
cat >"$tmp/bin/tailscale" <<'FAKE'
#!/usr/bin/env bash
[ "$*" = 'status --json' ] || exit 2
[ ! -e "$FAKE_SSH/unavailable" ] || exit 1
cat "$FAKE_SSH/status"
FAKE
cat >"$tmp/bin/nft" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
	'list table inet machine-ssh') [ -f "$FAKE_SSH/table" ] ;;
	-f\ *)
		cmp "$2" "$FAKE_SSH/rules" || exit 2
		[ ! -e "$FAKE_SSH/table" ] || exit 2
		touch "$FAKE_SSH/table"
		echo add >>"$FAKE_SSH/calls"
		;;
	'delete table inet machine-ssh')
		rm "$FAKE_SSH/table"
		echo delete >>"$FAKE_SSH/calls"
		;;
	*) exit 2 ;;
esac
FAKE
chmod +x "$tmp/bin/"*
cp "$1" "$tmp/rules"
: >"$tmp/calls"
checks=0
run() {
	local want=$1 got=0
	bash -o errexit -o nounset -o pipefail "$closer" "$tmp/rules" >"$tmp/said" 2>&1 || got=$?
	if [ "$got" != "$want" ]; then
		cat "$tmp/said" >&2
		echo "ssh state: expected exit $want, got $got" >&2
		exit 1
	fi
	checks=$((checks + 1))
}
status() { printf '{"BackendState":"%s","Self":{"Online":%s}}\n' "$1" "$2" >"$tmp/status"; }
fresh() {
	rm -rf "$tmp/run"
	rm -f "$tmp/table" "$tmp/unavailable"
	: >"$tmp/calls"
	export MACHINE_SSH_UPTIME=0.00
}
unhealthy() {
	rm -f "$tmp/unavailable"
	case "$1" in
	Online)
		status Running false
		reason="Online false"
		;;
	unavailable)
		touch "$tmp/unavailable"
		reason="tailscale status unavailable"
		;;
	Unknown)
		printf 'invalid\n' >"$tmp/status"
		reason="BackendState Unknown"
		;;
	*)
		status "$1" false
		reason="BackendState $1"
		;;
	esac
}

# A closed machine counts every unhealthy state even during the boot grace.
for backend in Starting Online NeedsLogin unavailable Unknown; do
	fresh
	status Running true
	run 0
	[ -f "$tmp/table" ] && [ "$(cat "$tmp/run/failures")" = 0 ]
	unhealthy "$backend"
	for i in 1 2 3 4; do
		run 0
		[ -f "$tmp/table" ] && [ "$(cat "$tmp/run/failures")" = "$i" ]
		[ "$(cat "$tmp/calls")" = add ]
	done
	run 1
	[ ! -e "$tmp/table" ] && [ "$(cat "$tmp/run/failures")" = 5 ]
	grep -qF "$reason after 5 consecutive unhealthy checks" "$tmp/said"
	[ "$(cat "$tmp/calls")" = $'add\ndelete' ]
	rm -f "$tmp/unavailable"
	status Running true
	run 0
	[ -f "$tmp/table" ] && [ "$(cat "$tmp/run/failures")" = 0 ]
	[ "$(cat "$tmp/calls")" = $'add\ndelete\nadd' ]
	echo "ssh state: table present, $backend retained through four checks, reopened at five, recovered"
done

fresh
status NeedsLogin false
for minute in {0..60}; do
	MACHINE_SSH_UPTIME=$((minute * 60)).00 run 0
	[ ! -e "$tmp/table" ] && [ "$(cat "$tmp/run/failures")" = 0 ]
done
[ ! -s "$tmp/calls" ]
echo "ssh state: table absent, NeedsLogin for an hour never counted or alarmed"

# An open machine has a grace through exactly 600 seconds for every other unhealthy state.
for backend in Starting Online unavailable; do
	fresh
	unhealthy "$backend"
	for second in 0 60 120 180 240 300 360 420 480 540 599.99 600.00; do
		MACHINE_SSH_UPTIME=$second run 0
		[ ! -e "$tmp/table" ] && [ "$(cat "$tmp/run/failures")" = 0 ]
	done
	export MACHINE_SSH_UPTIME=600.01
	for i in 1 2 3 4; do
		run 0
		[ ! -e "$tmp/table" ] && [ "$(cat "$tmp/run/failures")" = "$i" ]
	done
	run 1
	[ ! -e "$tmp/table" ] && [ "$(cat "$tmp/run/failures")" = 5 ]
	grep -qF "$reason after 5 consecutive unhealthy checks" "$tmp/said"
	[ ! -s "$tmp/calls" ]
	run 1
	[ ! -e "$tmp/table" ] && [ ! -s "$tmp/calls" ]
	rm -f "$tmp/unavailable"
	status NeedsLogin false
	run 0
	[ "$(cat "$tmp/run/failures")" = 0 ] && [ ! -e "$tmp/table" ]
	unhealthy "$backend"
	run 0
	[ "$(cat "$tmp/run/failures")" = 1 ] && [ ! -e "$tmp/table" ]
	echo "ssh state: table absent, $backend gated through 600 seconds, alarmed at five, login reset"
done

fresh
status Running true
run 0
unhealthy Starting
for _ in 1 2 3 4; do run 0; done
status Running true
run 0
[ -f "$tmp/table" ] && [ "$(cat "$tmp/run/failures")" = 0 ]
[ "$(cat "$tmp/calls")" = add ]
run 0
[ "$(cat "$tmp/calls")" = add ]
echo "ssh state: table present, healthy reset the streak without changing the table"

unhealthy Starting
for _ in 1 2 3 4; do run 0; done
rm "$tmp/table"
status Running true
run 0
[ -f "$tmp/table" ] && [ "$(cat "$tmp/run/failures")" = 0 ]
[ "$(cat "$tmp/calls")" = $'add\nadd' ]
echo "ssh state: healthy after a flush restored the table and reset the count without an alarm"
echo "ssh state: $checks checks passed"
