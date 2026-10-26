#!/usr/bin/env bash
# Sweeping preserves every remaining narinfo's NAR and expires old orphan NARs.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")/.." && pwd)
. "$cache_dir/test-support.sh"
setup_test
trap 'rm -rf "$t"' EXIT
. "$cache_dir/../protocol.sh"
. "$cache_dir/../run.sh"
builder=a1
work=$t/work
given=$t/sweep.json
jq '.machines={}' "$t/build.json" >"$given"
mv "$t/bin/rclone" "$t/bin/rclone-original"
cat >"$t/bin/rclone" <<'SH'
#!/usr/bin/env bash
if [ "$1" = deletefile ] && [ "$2" = "${TEST_DELETE_FAIL:-}" ]; then
	printf '%s\n' "$*" >>"$TEST_ROOT/events"
	exit 7
fi
if [ "$1" = cat ] && [ "$2" = "${TEST_READ_FAIL:-}" ]; then exit 7; fi
exec "$TEST_ROOT/bin/rclone-original" "$@"
SH
chmod +x "$t/bin/rclone"
hash=${path##*/}; hash=${hash%%-*}
other=${ref##*/}; other=${other%%-*}
failed=false
for scenario in delete-failure shared-protected shared-recent shared-failure unreadable orphan expired; do
	objects=$t/$scenario
	mkdir -p "$objects/nar" "$objects/self"
	echo data >"$objects/nar/shared.nar.zst"
	if [ "$scenario" != orphan ]; then
		printf 'URL: nar/shared.nar.zst\nReferences: \n' >"$objects/$hash.narinfo"
	fi
	case $scenario in
	shared-*)
		cp "$objects/$hash.narinfo" "$objects/$other.narinfo" ;;
	esac
	if [ "$scenario" = shared-protected ]; then
		cache_record 2026-10-26T13:00:00Z "$ref" "$objects/self/a1"
	fi
	find "$objects" -type f -exec touch -d 2026-10-25T10:00:00Z {} +
	if [[ $scenario == shared-recent || $scenario == unreadable ]]; then
		recent=$other
		if [ "$scenario" = unreadable ]; then recent=$hash; fi
		touch -d 2026-10-26T13:59:00Z "$objects/$recent.narinfo"
	fi
	export TEST_DELETE_FAIL=""
	export TEST_READ_FAIL=""
	sweep_refused=false
	case $scenario in
	delete-failure) TEST_DELETE_FAIL=$objects/$hash.narinfo ;;
	shared-failure) TEST_DELETE_FAIL=$objects/$other.narinfo ;;
	unreadable) TEST_READ_FAIL=$objects/$hash.narinfo ;;
	esac
	: >"$t/events"
	sweep >"$t/delete-log" 2>"$t/delete-errors"
	ok=true
	case $scenario in
	delete-failure)
		[ -f "$objects/$hash.narinfo" ] && [ -f "$objects/nar/shared.nar.zst" ] || ok=false
		! grep -qxF "deletefile $objects/nar/shared.nar.zst" "$t/events" || ok=false ;;
	shared-*)
		[ ! -f "$objects/$hash.narinfo" ] && [ -f "$objects/$other.narinfo" ] \
			&& [ -f "$objects/nar/shared.nar.zst" ] || ok=false ;;
	unreadable)
		[ -f "$objects/$hash.narinfo" ] && [ -f "$objects/nar/shared.nar.zst" ] \
			&& [ "$sweep_refused" = true ] || ok=false
		grep -q 'remaining narinfo' "$t/delete-errors" || ok=false ;;
	orphan)
		[ ! -f "$objects/nar/shared.nar.zst" ] || ok=false ;;
	expired)
		[ ! -f "$objects/$hash.narinfo" ] && [ ! -f "$objects/nar/shared.nar.zst" ] || ok=false
		[ "$(grep '^deletefile ' "$t/events")" = "deletefile $objects/$hash.narinfo
deletefile $objects/nar/shared.nar.zst" ] || ok=false ;;
	esac
	if [ "$ok" = true ]; then
		echo "sweep deletion passed $scenario"
	else
		echo "sweep deletion failed $scenario" >&2
		failed=true
	fi
done
[ "$failed" = false ]
