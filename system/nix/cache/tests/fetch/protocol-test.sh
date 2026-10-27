#!/usr/bin/env bash
# Pointers and claims are tested with advancing clocks and real local signatures.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")/.." && pwd)
. "$cache_dir/test-support.sh"
setup_test
trap 'rm -rf "$t"' EXIT
. "$cache_dir/../protocol.sh"
pointer a1 2026-10-26T12:00:00Z
pointer a2 2026-10-26T13:00:00Z
# Each fetch realizes its system with a root, the bucket, upstream and their trust, docs/store.md.
trust="--option substituters file://$t/bucket https://example\.com/upstream"
trust+=" --option trusted-public-keys example\.com:key example\.com-upstream:key"
trust+=" --option require-sigs true --option narinfo-cache-negative-ttl 0"
realized() { grep -Ec -- "^--realise $path --add-root /.+/system $trust$" "$t/nix-calls" || true; }
fetch_test
[ "$(jq -r .at "$MACHINE_CACHE_APPLIED")" = 2026-10-26T13:00:00Z ]
[ "$(realized)" = 1 ]
pointer a1 2026-10-26T14:00:00Z
fetch_test
[ "$(realized)" = 2 ]
pointer a1 2026-10-26T15:00:01Z
pointer a2 2026-10-26T14:01:00Z
fetch_test 2>"$t/refused"
grep -q 'pending/c1/a1 refused' "$t/refused"
[ "$(jq -r .at "$MACHINE_CACHE_APPLIED")" = 2026-10-26T14:01:00Z ]
cp "$t/a1.signers" "$t/a2.signers"
if fetch_test; then echo "wrong builder key accepted" >&2; exit 1; fi
printf 'builder namespaces="machine-cache" %s\n' "$(cat "$t/a2.pub")" >"$t/a2.signers"
pointer a1 2026-10-26T14:00:00Z
pointer a2 2026-10-26T14:01:00Z
clock_at 2026-10-28T14:01:01Z
if fetch_test; then echo "two day alarm missing" >&2; exit 1; fi
clock_at 2026-10-26T14:00:00Z
export MACHINE_CACHE_FALLBACK=true
status=0; fetch_test || status=$?
[ "$status" = 2 ]
unset MACHINE_CACHE_FALLBACK
rm -f "$MACHINE_CACHE_APPLIED" "$t/bucket/pending/c1/"*
fetch_test
[ -f "$MACHINE_CACHE_STARTED" ]
clock_at 2026-10-28T14:00:00Z
if fetch_test; then echo "new installation alarm missing" >&2; exit 1; fi
clock_at 2026-10-26T14:00:00Z
. "$cache_dir/../run.sh"
given=$t/build.json
machine=c1; builder=a1; prefix=pending/c1/a1; gap=20; manual=false; system=$path
objects=$t/bucket; work=$t/work
slot_minute
slot 2>"$t/slot-errors"
[ ! -s "$t/slot-errors" ]
[ -f "$objects/$prefix.claim" ]
status=0; slot || status=$?; [ "$status" = 2 ]
clock_at 2026-10-26T14:20:00Z
builder=a2; prefix=pending/c1/a2
slot_minute
printf '%s\n' 2026-10-26T14:00:30Z >"$objects/pending/c1/a1.claim"
slot
rm -f "$objects/pending/c1/a2.claim"
printf '%s\n' 2026-10-26T14:19:30Z >"$objects/pending/c1/a1.claim"
clock_at 2026-10-26T14:20:00Z
"$CACHE_TEST_DATE" -u -d 2026-10-26T14:40:00Z +%s >"$t/advance-on-claim"
slot
rm -f "$t/advance-on-claim" "$objects/pending/c1/"*
clock_at 2026-10-26T00:00:00Z
jq '.machines.c1.slots=["00:00","00:20"]' "$given" >"$t/midnight.json"
given=$t/midnight.json; builder=a1; prefix=pending/c1/a1
slot_minute
slot
[ -f "$objects/$prefix.claim" ]
rm -f "$objects/pending/c1/"*
jq '.machines.c1.slots=["23:40","00:00"] | .machines.c1.slotDays=[-1,0]' "$t/build.json" >"$t/wrapped.json"
given=$t/wrapped.json
clock_at 2026-10-26T23:40:00Z
slot_minute
[ "$slot_day" = 2026-10-27 ]
slot
pointer a1 2026-10-26T23:40:00Z
clock_at 2026-10-27T00:00:00Z
builder=a2; prefix=pending/c1/a2
slot_minute
status=0; slot || status=$?; [ "$status" = 2 ]
given=$t/build.json
clock_at 2026-10-26T14:00:00Z
rm -f "$objects/pending/c1/"*
run_test --now
if [ ! -f "$objects/pending/c1/a1" ]; then fail "confirmation pointer missing"; fi
if [ ! -f "$objects/pending/c1/a1.sig" ]; then fail "confirmation signature missing"; fi
if [ -f "$objects/pending/c1/a1.objects" ]; then fail "confirmation object list present"; fi
clock_at 2026-10-27T14:01:00Z
run_test --now
if [ "$(jq -r .at "$objects/pending/c1/a1")" != 2026-10-27T14:01:00Z ]; then
	fail "confirmation timestamp not refreshed"
fi
ssh-keygen -Y verify -f "$t/a1.signers" -I builder -n machine-cache \
	-s "$objects/pending/c1/a1.sig" <"$objects/pending/c1/a1" >/dev/null
rm -f "$objects/pending/c1/"*
echo legacy >"$t/legacy"
rmdir "$objects/pending/c1"
cp "$t/legacy" "$objects/pending/c1"
if run_test --now >"$t/layout" 2>&1; then echo "legacy layout accepted" >&2; exit 1; fi
grep -q 'legacy pointer pending/c1 must be moved aside' "$t/layout"
echo "protocol: signatures, newest valid, alarms, fallback, moving claims, empty claims and confirmation passed"
