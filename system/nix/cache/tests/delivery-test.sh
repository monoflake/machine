#!/usr/bin/env bash
# Consumer deltas are published before pointers and checked against the closure and cap.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")" && pwd)
. "$cache_dir/test-support.sh"
setup_test
trap 'rm -rf "$t"' EXIT
printf '%s\n' "$ref" >"$t/hosts/c1/current"
run_test --now
cmp "$t/closure" "$t/closure-asked"
grep -qx 'c1 lacks' "$t/asked"
[ -f "$t/bucket/pending/c1/a1.objects" ]
[ "$(wc -l <"$t/bucket/pending/c1/a1.objects" | tr -d ' ')" = 2 ]
[ -f "$t/bucket/pending/c1/a1" ]
[ ! -f "$t/bucket/1123456789abcdfghijklmnpqrsvwxyz.narinfo" ]
delta_line=$(grep -n 'copyto .*pending/c1/a1.objects$' "$t/events" | cut -d: -f1)
pointer_line=$(grep -n 'copyto .*pending/c1/a1$' "$t/events" | cut -d: -f1)
[ "$delta_line" -lt "$pointer_line" ]
export MACHINE_CACHE_CONFIG=$t/fetch.json
fetch_test
[ "$(jq -r .path "$MACHINE_CACHE_APPLIED")" = "$path" ]
rm -f "$t/bucket/pending/c1/"* "$t/bucket/"*.narinfo "$t/bucket/nar/"* "$t/bucket/nix-cache-info"
echo /nix/store/2123456789abcdfghijklmnpqrsvwxyz-outside >"$t/hosts/c1/lacks"
if run_test --now >"$t/outside" 2>&1; then echo "outside closure accepted" >&2; exit 1; fi
grep -q 'outside its closure' "$t/outside"
[ ! -f "$t/bucket/pending/c1/a1" ]
echo "$path" >"$t/hosts/c1/lacks"
rm -f "$t/bucket/pending/c1/"*
jq '.cap=80' "$t/build.json" >"$t/capped.json"
mv "$t/capped.json" "$t/build.json"
if run_test --now >"$t/cap" 2>&1; then echo "nonzero delta cap ignored" >&2; exit 1; fi
grep -Eq 'delta [1-9][0-9]* more' "$t/cap"
[ ! -f "$t/bucket/pending/c1/a1" ]
[ ! -f "$t/bucket/0123456789abcdfghijklmnpqrsvwxyz.narinfo" ]
echo "delivery: lacks, closure refusal, delta ordering, fetch and nonzero cap passed"
