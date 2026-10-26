#!/usr/bin/env bash
# A marker outside pending cannot answer any consumer pointer reader.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")/.." && pwd)
. "$cache_dir/test-support.sh"
setup_test
trap 'rm -rf "$t"' EXIT
. "$cache_dir/../protocol.sh"
mkdir -p "$t/bucket/self" "$t/bucket/nar"
h=${path##*/}; h=${h%%-*}
printf 'URL: nar/%s.nar.zst\nReferences: \n' "$h" >"$t/bucket/$h.narinfo"
touch "$t/bucket/nar/$h.nar.zst"
cache_record 2026-10-26T14:00:00Z "$path" "$t/bucket/self/c1"
export MACHINE_CACHE_FALLBACK=true
status=0
fetch_test >"$t/fetch-log" 2>"$t/fetch-errors" || status=$?
[ "$status" = 2 ] && [ ! -s "$t/fetch-errors" ]
[ ! -f "$MACHINE_CACHE_APPLIED" ] && [ ! -f "$t/nix-calls" ]
. "$cache_dir/../run.sh"
given=$t/build.json
machine=c1; builder=a1; prefix=pending/c1/a1; gap=20; manual=false; system=$path
objects=$t/bucket; work=$t/work
slot_minute
slot
[ -f "$objects/$prefix.claim" ]
! grep -q '^cat .*/self/' "$t/events"
: >"$t/events"
sweep >"$t/sweep-log" 2>"$t/sweep-errors"
[ ! -s "$t/sweep-errors" ]
grep -q '^cat .*/self/c1$' "$t/events"
! grep -q 'pointer\|passed over' "$t/sweep-log"
[ -f "$work/pointers" ] && [ ! -s "$work/pointers" ] && [ ! -f "$t/asked" ]
[ -f "$objects/self/c1" ]
echo "self marker readers passed fetch, slot and the sweep pointer loop"
