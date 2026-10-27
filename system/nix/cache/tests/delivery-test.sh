#!/usr/bin/env bash
# Consumer deliveries upload their own set before the pointer while the bucket is under the cap.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")" && pwd)
. "$cache_dir/test-support.sh"
setup_test
trap 'rm -rf "$t"' EXIT
printf '%s\n' "$ref" >"$t/hosts/c1/current"
run_test --now
if grep -q lacks "$t/asked"; then fail "the run asked the machine what it lacks"; fi
[ -f "$t/bucket/pending/c1/a1" ]
[ ! -f "$t/bucket/pending/c1/a1.objects" ]
[ -f "$t/bucket/0123456789abcdfghijklmnpqrsvwxyz.narinfo" ]
[ ! -f "$t/bucket/1123456789abcdfghijklmnpqrsvwxyz.narinfo" ]
narinfo_line=$(grep -n '^copy .*/upload-narinfo ' "$t/events" | cut -d: -f1)
pointer_line=$(grep -n 'copyto .*pending/c1/a1$' "$t/events" | cut -d: -f1)
[ "$narinfo_line" -lt "$pointer_line" ]
export MACHINE_CACHE_CONFIG=$t/fetch.json
fetch_test
[ "$(jq -r .path "$MACHINE_CACHE_APPLIED")" = "$path" ]
rm -f "$t/bucket/pending/c1/"* "$t/bucket/"*.narinfo "$t/bucket/nar/"* "$t/bucket/nix-cache-info"
jq '.cap=80' "$t/build.json" >"$t/capped.json"
mv "$t/capped.json" "$t/build.json"
# Under the cap the run uploads, its own set never added to the bucket's total.
run_test --now >"$t/under" 2>&1 || { cat "$t/under" >&2; exit 1; }
[ -f "$t/bucket/pending/c1/a1" ]
[ -f "$t/bucket/0123456789abcdfghijklmnpqrsvwxyz.narinfo" ]
rm -f "$t/bucket/pending/c1/"* "$t/bucket/"*.narinfo "$t/bucket/nar/"* "$t/bucket/nix-cache-info"
printf '%0100d' 0 >"$t/bucket/stray"
: >"$t/uploaded"
if run_test --now >"$t/cap" 2>&1; then echo "bucket past the cap accepted" >&2; exit 1; fi
# The stray object, the run's own nix-cache-info and its claim, 100, 21 and 21 bytes.
grep -q "the bucket holds 142 bytes, past the cap of 80; nothing uploaded" "$t/cap" || { cat "$t/cap" >&2; exit 1; }
[ "$(tail -n 1 "$t/cap")" = 'machine-cache outcome=failed consumer=c1' ]
[ ! -s "$t/uploaded" ]
[ ! -f "$t/bucket/pending/c1/a1" ]
[ ! -f "$t/bucket/0123456789abcdfghijklmnpqrsvwxyz.narinfo" ]
[ "$(grep -c '^size ' "$t/events")" = 3 ]
echo "delivery: own set, ordering, fetch, a bucket under the cap and one past it passed"
