#!/usr/bin/env bash
# A real held lock cannot make the assigned slot disappear silently.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")" && pwd)
. "$cache_dir/test-support.sh"
setup_test
holder_pid=""
trap '[ -z "$holder_pid" ] || { echo release >"$t/release"; wait "$holder_pid"; }; rm -rf "$t"' EXIT
mkfifo "$t/release"
(
	exec 9>>"$t/lock"
	flock -w 0 9
	echo c2 >"$t/lock.owner"
	touch "$t/ready"
	read -r _ <"$t/release"
) &
holder_pid=$!
for _ in {1..100}; do [ ! -f "$t/ready" ] || break; sleep 0.01; done
[ -f "$t/ready" ]
clock_at 2026-10-26T14:20:59Z
run_test
clock_at 2026-10-26T14:00:59Z
if run_test >"$t/missed" 2>&1; then echo "held lock lost the slot silently" >&2; exit 1; fi
grep -q 'slot missed: lock held by c2' "$t/missed"
echo release >"$t/release"
wait "$holder_pid"; holder_pid=""
[ ! -f "$t/build-calls" ]
echo "lock: wrong slots skip before locking and a real held lock fails the assigned slot"
clock_at 2026-10-26T14:05:00Z
TRIGGER_TIMER_REALTIME_USEC=$(($("$CACHE_TEST_DATE" -u -d 2026-10-26T14:00:00Z +%s) * 1000000)) run_test
[ -f "$t/bucket/pending/c1/a1" ]
clock_at 2026-10-26T14:20:01Z
if TRIGGER_TIMER_REALTIME_USEC=$(($("$CACHE_TEST_DATE" -u -d 2026-10-26T14:00:00Z +%s) * 1000000)) \
	run_test >"$t/late" 2>&1; then echo "expired timer start accepted" >&2; exit 1; fi
grep -q 'slot missed: started late' "$t/late"
clock_at 2026-10-26T14:45:00Z
if run_test >"$t/late-no-trigger" 2>&1; then echo "expired start accepted" >&2; exit 1; fi
grep -q 'slot missed: started late' "$t/late-no-trigger"
echo "lock: starts inside the gap run and starts after the gap fail"
