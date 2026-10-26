#!/usr/bin/env bash
# Every builder keeps marked closures through references while superseded systems expire.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")/.." && pwd)
. "$cache_dir/test-support.sh"
setup_test
trap 'rm -rf "$t"' EXIT
. "$cache_dir/../protocol.sh"
. "$cache_dir/../run.sh"
builder=a1
objects=$t/bucket
work=$t/work
given=$t/sweep.json
jq '.machines={}' "$t/build.json" >"$given"
mkdir -p "$objects/self" "$objects/nar"
old=/nix/store/2123456789abcdfghijklmnpqrsvwxyz-old
new=/nix/store/3123456789abcdfghijklmnpqrsvwxyz-new
unmarked=/nix/store/4123456789abcdfghijklmnpqrsvwxyz-unmarked
for p in "$path" "$old" "$new" "$unmarked"; do
	h=${p##*/}; h=${h%%-*}
	printf 'URL: nar/%s.nar.zst\nReferences: %s\n' "$h" "${ref##*/}" >"$objects/$h.narinfo"
	touch "$objects/nar/$h.nar.zst"
done
h=${ref##*/}; h=${h%%-*}
printf 'URL: nar/%s.nar.zst\nReferences: \n' "$h" >"$objects/$h.narinfo"
touch "$objects/nar/$h.nar.zst" "$objects/nix-cache-info"
cache_record 2026-10-25T10:00:00Z "$path" "$objects/self/a1"
cache_record 2026-10-25T10:00:00Z "$old" "$objects/self/a2"
echo '{' >"$objects/self/invalid"
find "$objects" -type f -exec touch -d 2026-10-25T10:00:00Z {} +
sweep >"$t/sweep-log"
for p in "$path" "$ref" "$old"; do
	h=${p##*/}; h=${h%%-*}
	[ -f "$objects/$h.narinfo" ] && [ -f "$objects/nar/$h.nar.zst" ]
done
for p in "$new" "$unmarked"; do
	h=${p##*/}; h=${h%%-*}
	[ ! -f "$objects/$h.narinfo" ] && [ ! -f "$objects/nar/$h.nar.zst" ]
done
[ -f "$objects/self/a1" ] && [ -f "$objects/self/a2" ] && [ -f "$objects/self/invalid" ]
[ ! -f "$t/asked" ]
h=${new##*/}; h=${h%%-*}
printf 'URL: nar/%s.nar.zst\nReferences: %s\n' "$h" "${ref##*/}" >"$objects/$h.narinfo"
touch "$objects/nar/$h.nar.zst"
cache_record 2026-10-26T13:00:00Z "$new" "$objects/self/a2"
find "$objects" -type f -exec touch -d 2026-10-25T10:00:00Z {} +
builder=a2
sweep >"$t/newest-log"
for p in "$path" "$ref" "$new"; do
	h=${p##*/}; h=${h%%-*}
	[ -f "$objects/$h.narinfo" ] && [ -f "$objects/nar/$h.nar.zst" ]
done
h=${old##*/}; h=${h%%-*}
[ ! -f "$objects/$h.narinfo" ] && [ ! -f "$objects/nar/$h.nar.zst" ]
[ "$(jq -r .path "$objects/self/a2")" = "$new" ]
[ -f "$objects/self/a1" ] && [ -f "$objects/nix-cache-info" ]
echo "self marker sweep passed marked references, unmarked expiry and newest replacement across builders"

jq '.machines={c1:{host:"c1"}}' "$given" >"$t/refusal.json"
given=$t/refusal.json
rmdir "$objects/pending/c1"
jq -n --arg p "$path" '{machine:"c1",path:$p,at:"2026-10-26T11:00:00Z"}' \
	>"$objects/pending/c1"
echo signature >"$objects/pending/c1.sig"
echo stray >"$objects/pending/c1.objects"
echo unprotected >"$objects/stray"
find "$objects" -type f -exec touch -d 2026-10-25T10:00:00Z {} +
mv "$t/bin/rclone" "$t/bin/rclone-original"
cat >"$t/bin/rclone" <<'SH'
#!/usr/bin/env bash
if [ "$1" = cat ] && [ "$2" = "$TEST_UNREADABLE" ]; then exit 7; fi
exec "$TEST_ROOT/bin/rclone-original" "$@"
SH
chmod +x "$t/bin/rclone"
snapshot() { (cd "$objects" && find . -type f | sort | xargs sha256sum); }
snapshot >"$t/before-refusal"
cp -a "$objects" "$t/refusal-bucket"
failed=false
for unreadable in self/a1 1123456789abcdfghijklmnpqrsvwxyz.narinfo; do
	cp -a "$t/refusal-bucket/." "$objects/"
	export TEST_UNREADABLE=$objects/$unreadable
	: >"$t/events"
	sweep >"$t/refusal-log" 2>"$t/refusal-errors"
	snapshot >"$t/after-refusal"
	if cmp -s "$t/before-refusal" "$t/after-refusal" \
		&& ! grep -q '^deletefile ' "$t/events" \
		&& grep -q 'sweep refused' "$t/refusal-errors" \
		&& grep -qF "$unreadable" "$t/refusal-errors"; then
		echo "self marker sweep passed refusing all deletion for unreadable $unreadable"
	else
		echo "self marker sweep failed refusing all deletion for unreadable $unreadable" >&2
		failed=true
	fi
done
[ "$failed" = false ]
