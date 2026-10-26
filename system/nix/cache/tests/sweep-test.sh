#!/usr/bin/env bash
# The sweep retires owned older pointers and old unreferenced objects while protecting uploads.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")" && pwd)
. "$cache_dir/test-support.sh"
setup_test
trap 'rm -rf "$t"' EXIT
. "$cache_dir/../protocol.sh"
. "$cache_dir/../run.sh"
builder=a1
objects=$t/bucket
work=$t/work
given=$t/sweep.json
jq -n --arg t "$t" '{accessKey:($t+"/a1"),tailnet:true,machines:(["c1","c2","c3","c4","c5","c6","c7","c8","c9","c10"] | map({key:.,value:{host:.}}) | from_entries)}' >"$given"
for m in c1 c2 c8 c9 c10; do
	mkdir -p "$t/hosts/$m" "$objects/pending/$m"
	pointer a1 2026-10-26T11:00:00Z "$m"
done
pointer a2 2026-10-26T13:00:00Z c1
pointer a2 2026-10-26T13:00:00Z c9
for m in c1 c8 c9 c10; do
	jq -n '{at:"2026-10-26T13:00:00Z"}' >"$t/hosts/$m/applied"
done
jq -n '{at:"2026-10-26T11:00:00Z"}' >"$t/hosts/c1/applied"
for m in c1 c2; do
	echo "$m-old.narinfo" >"$objects/pending/$m/a1.objects"
	touch "$objects/$m-old.narinfo"
done
echo c1-new.narinfo >"$objects/pending/c1/a2.objects"
touch "$objects/c1-new.narinfo"
for m in c4 c5 c6 c7; do mkdir -p "$objects/pending/$m"; done
echo '{"machine":"c4"}' >"$objects/pending/c4/a1"
echo '{' >"$objects/pending/c5/a1"
echo 7 >"$objects/pending/c6/a1"
echo '{"path":7,"at":"2026-10-26T13:00:00Z"}' >"$objects/pending/c7/a1"
mkdir -p "$objects/nar"
printf 'URL: nar/c8.nar.zst\nReferences: 1123456789abcdfghijklmnpqrsvwxyz-reference\n' >"$objects/0123456789abcdfghijklmnpqrsvwxyz.narinfo"
echo 'URL: nar/reference.nar.zst' >"$objects/1123456789abcdfghijklmnpqrsvwxyz.narinfo"
touch "$objects/nar/c8.nar.zst" "$objects/nar/reference.nar.zst" "$objects/stray.narinfo" "$objects/nix-cache-info"
find "$objects" -type f -exec touch -d 2026-10-26T10:00:00Z {} +
touch "$objects/nar/a2-mid-upload.nar.zst"
touch -d 2026-10-26T13:59:00Z "$objects/nar/a2-mid-upload.nar.zst"
sweep >"$t/sweep-log" 2>"$t/sweep-errors"
[ "$(cat "$t/asked")" = "c1 applied
c10 applied
c2 applied
c8 applied
c9 applied" ]
[ "$(grep -c 'passed over' "$t/sweep-log")" = 4 ]
grep -q 'could not ask c2' "$t/sweep-log"
[ -f "$objects/pending/c1/a1" ] && [ -f "$objects/c1-old.narinfo" ]
[ -f "$objects/pending/c2/a1" ] && [ -f "$objects/c2-old.narinfo" ]
[ ! -f "$objects/pending/c9/a1" ]
[ -f "$objects/pending/c9/a2" ]
[ ! -f "$objects/stray.narinfo" ]
[ -f "$objects/nar/a2-mid-upload.nar.zst" ]
[ -f "$objects/nar/c8.nar.zst" ] && [ -f "$objects/nar/reference.nar.zst" ]
[ -f "$objects/pending/c8/a1" ] && [ ! -f "$objects/pending/c8/a1.objects" ]
jq -n '{at:"2026-10-26T13:00:00Z"}' >"$t/hosts/c1/applied"
sweep >"$t/sweep-again" 2>>"$t/sweep-errors"
[ ! -f "$objects/pending/c1/a1" ] && [ ! -f "$objects/c1-old.narinfo" ]
[ -f "$objects/pending/c1/a2" ] && [ -f "$objects/c1-new.narinfo" ]
[ -f "$objects/pending/c2/a1" ]
[ -f "$objects/nix-cache-info" ]
echo "sweep: malformed, absent, unaskable, owned retirement, newest closure and recent uploads passed"
jq '.machines += {c11:{host:"c11"},c12:{host:"c12"},c13:{host:"c13"}}' "$given" >"$t/legacy-sweep.json"
given=$t/legacy-sweep.json
for m in c11 c12 c13; do
	jq -n --arg m "$m" --arg path "$path" \
		'{machine:$m,path:$path,at:"2026-10-26T11:00:00Z"}' >"$objects/pending/$m"
	echo signature >"$objects/pending/$m.sig"
	echo "$m-old.narinfo" >"$objects/pending/$m.objects"
	touch -d 2026-10-26T10:00:00Z "$objects/$m-old.narinfo"
done
mkdir -p "$t/hosts/c11" "$t/hosts/c12"
echo "$path" >"$t/hosts/c11/current"
echo "$ref" >"$t/hosts/c12/current"
: >"$t/asked"
sweep >"$t/legacy-sweep-log" 2>>"$t/sweep-errors"
[ "$(grep -E '^c1[123] ' "$t/asked")" = "c11 current
c12 current
c13 current" ]
[ ! -f "$objects/pending/c11" ] && [ ! -f "$objects/pending/c11.sig" ]
[ ! -f "$objects/pending/c11.objects" ] && [ ! -f "$objects/c11-old.narinfo" ]
[ -f "$objects/pending/c12" ] && [ -f "$objects/c12-old.narinfo" ]
[ -f "$objects/pending/c13" ] && [ -f "$objects/c13-old.narinfo" ]
[ -f "$objects/pending/c1/a2" ]
echo "sweep: legacy pointers retire on current while per-builder newest pointers remain"
