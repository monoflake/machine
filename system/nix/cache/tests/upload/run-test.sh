#!/usr/bin/env bash
# A run uploads what upstream lacks, all of it again each time and the pointer last, and publishes
# nothing where upstream cannot be asked, docs/cache.md.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")/.." && pwd)
. "$cache_dir/test-support.sh"
setup_test
trap 'rm -rf "$t"' EXIT
own=${path##*/}; own=${own%%-*}
other=${ref##*/}; other=${other%%-*}
echo "$ref" >"$t/hosts/c1/current"
expected=$(printf '%s\n' "nar/$own.nar.zst" "$own.narinfo")
# What a run may write when it publishes nothing, its claim and nix-cache-info.
published() {
	grep -E '^(copy|copyto|deletefile) ' "$t/events" | grep -vE '\.claim$| [^ ]*/nix-cache-info$' || true
}

run_test --now >"$t/log"
[ "$(sort "$t/uploaded")" = "$(sort <<<"$expected")" ]
[ ! -f "$t/bucket/$other.narinfo" ]
[ ! -f "$t/bucket/nar/$other.nar.zst" ]
grep -q "^path-info --store file://$t/upstream .* --json .*--stdin$" "$t/build-calls"
[ "$(grep -c '^size --fast-list --json ' "$t/events")" = 1 ]
if grep -qE '^(ls|lsd|lsf|lsl|lsjson|tree|ncdu|sync|check|cryptcheck) ' "$t/events"; then
	fail "the run listed the bucket"
fi
if grep -q lacks "$t/asked"; then fail "the run asked the machine what it lacks"; fi
asked="-s -L --max-redirs 5 --max-time 20 --retry 2 --retry-connrefused -o /dev/null"
asked+=" -w %{http_code} $own\n file://$t/upstream/$own.narinfo"
[ "$(cat "$t/curl-calls")" = "$asked" ]
echo "upload run passed uploading only the paths upstream lacks, with one size and no listing"

info=$(grep -n "^copyto --no-check-dest .* $t/bucket/nix-cache-info$" "$t/events" | cut -d: -f1)
data=$(grep -n '^copy .*/upload-data ' "$t/events" | cut -d: -f1)
narinfo=$(grep -n '^copy .*/upload-narinfo ' "$t/events" | cut -d: -f1)
signature=$(grep -n "^copyto .* $t/bucket/pending/c1/a1.sig$" "$t/events" | cut -d: -f1)
[ "$info" = 1 ]
[ "$data" -lt "$narinfo" ]
[ "$narinfo" -lt "$signature" ]
[[ $(tail -n 1 "$t/events") == "copyto "*" $t/bucket/pending/c1/a1" ]]
echo "upload run passed nix-cache-info first, then NARs, narinfos and the signed pointer last"

# The keys already there are uploaded again, so each object's age is the latest run's.
find "$t/bucket" -type f -exec touch -d 2026-10-25T10:00:00Z {} +
rm "$t/bucket/pending/c1/"*
: >"$t/uploaded"
: >"$t/events"
run_test --now >"$t/again"
[ "$(sort "$t/uploaded")" = "$(sort <<<"$expected")" ]
while read -r o; do
	[ "$(stat -c %Y "$t/bucket/$o")" -gt "$("$CACHE_TEST_DATE" -u -d 2026-10-26T00:00:00Z +%s)" ]
done < <(printf '%s\n' "$expected" nix-cache-info)
echo "upload run passed uploading every key of its own set again where the bucket holds it"

# Upstream not reached, a day later so the last pointer is no fresh answer.
cp "$t/bucket/pending/c1/a1" "$t/old-pointer"
cp "$t/bucket/pending/c1/a1.sig" "$t/old-signature"
clock_at 2026-10-27T14:00:00Z
for upstream in down partial forbidden; do
	case $upstream in
	partial)
		mv "$t/bin/nix" "$t/bin/nix-original"
		cat >"$t/bin/nix" <<'SH'
#!/usr/bin/env bash
if [[ $1 == path-info && $2 == --store ]]; then echo '{}'; exit; fi
exec "$TEST_ROOT/bin/nix-original" "$@"
SH
		chmod +x "$t/bin/nix" ;;
	forbidden)
		mv "$t/bin/nix-original" "$t/bin/nix"
		# Nix reads the 403 as a missing path, and only the second question sees it.
		touch "$t/upstream/$own.narinfo.forbidden" ;;
	esac
	: >"$t/uploaded"
	: >"$t/events"
	rm -f "$t/bucket/pending/c1/a1.claim"
	status=0
	if [ "$upstream" = down ]; then
		TEST_UPSTREAM=down run_test --now >"$t/unreached" 2>&1 || status=$?
	else run_test --now >"$t/unreached" 2>&1 || status=$?
	fi
	[ "$status" = 1 ] || { cat "$t/unreached" >&2; fail "upstream $upstream returned $status"; }
	[ "$(tail -n 1 "$t/unreached")" = 'machine-cache outcome=failed consumer=c1' ]
	grep -q "machine-cache: upstream file://$t/upstream .*; nothing published" "$t/unreached"
	[ "$upstream" != forbidden ] || grep -q "answered 403 $own.narinfo; nothing published" "$t/unreached"
	[ ! -s "$t/uploaded" ]
	[ -z "$(published)" ] || fail "upstream $upstream still published $(published)"
	cmp "$t/old-pointer" "$t/bucket/pending/c1/a1"
	cmp "$t/old-signature" "$t/bucket/pending/c1/a1.sig"
	echo "upload run passed publishing nothing where upstream is $upstream"
done
rm "$t/upstream/$own.narinfo.forbidden"

# A store reference with parameters, its narinfo asked without them, and redirects followed to a
# 404 and to a 200.
jq --arg t "$t" '.upstream=("file://"+$t+"/upstream?priority=40")' "$t/build.json" >"$t/query.json"
for move in lacking held; do
	rm -f "$t/bucket/pending/c1/"*
	: >"$t/curl-calls"
	: >"$t/uploaded"
	target=$t/upstream/gone.narinfo
	[ "$move" = lacking ] || target=$t/upstream/$other.narinfo
	echo "$target" >"$t/upstream/$own.narinfo.redirect"
	MACHINE_CACHE_CONFIG=$t/query.json bash -euo pipefail "$t/run.sh" c1 --now >"$t/moved" 2>&1 \
		|| { cat "$t/moved" >&2; fail "a redirect to the $move path failed the run"; }
	[ "$(cat "$t/curl-calls")" = "$asked" ] || fail "asked $(cat "$t/curl-calls")"
	if [ "$move" = lacking ]; then
		[ "$(sort "$t/uploaded")" = "$(sort <<<"$expected")" ]
	else
		[ ! -s "$t/uploaded" ]
	fi
	[ -f "$t/bucket/pending/c1/a1" ]
	echo "upload run passed a query on the store and a redirect to a $move path"
done
rm "$t/upstream/$own.narinfo.redirect"

# The machine already runs the system, and the confirming pointer still refreshes nix-cache-info.
rm "$t/bucket/nix-cache-info" "$t/bucket/pending/c1/"*
echo "$path" >"$t/hosts/c1/current"
: >"$t/events"
run_test --now >"$t/confirmed"
[ "$(tail -n 1 "$t/confirmed")" = 'machine-cache outcome=confirmed consumer=c1' ]
[ -f "$t/bucket/nix-cache-info" ]
[[ $(head -n 1 "$t/events") == "copyto --no-check-dest "*" $t/bucket/nix-cache-info" ]]
echo "upload run passed refreshing nix-cache-info first on a confirming run"
echo "$ref" >"$t/hosts/c1/current"

# One unnamed builder, so a retry is held by no claim.
jq --arg t "$t" '.bucket=($t+"/retry-bucket") | .machines.c1.builders={}' "$t/build.json" \
	>"$t/retry.json"
export MACHINE_CACHE_CONFIG=$t/retry.json
mv "$t/bin/rclone" "$t/bin/rclone-original"
cat >"$t/bin/rclone" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = copy ] && [ -f "$TEST_ROOT/interrupt-upload" ] && [[ $* == */upload-narinfo\ * ]]; then
	exit 7
fi
exec "$TEST_ROOT/bin/rclone-original" "$@"
SH
chmod +x "$t/bin/rclone"
touch "$t/interrupt-upload"
status=0
bash -euo pipefail "$t/run.sh" c1 --now >"$t/interrupted-log" 2>&1 || status=$?
[ "$status" = 7 ]
[ "$(tail -n 1 "$t/interrupted-log")" = 'machine-cache outcome=failed consumer=c1' ]
[ -f "$t/retry-bucket/nar/$own.nar.zst" ]
[ ! -f "$t/retry-bucket/$own.narinfo" ]
[ ! -f "$t/retry-bucket/pending/c1" ]
rm "$t/interrupt-upload"
bash -euo pipefail "$t/run.sh" c1 --now >"$t/retry-log"
[ -f "$t/retry-bucket/nar/$own.nar.zst" ]
[ -f "$t/retry-bucket/$own.narinfo" ]
[ -f "$t/retry-bucket/pending/c1" ]
[ ! -f "$t/retry-bucket/$other.narinfo" ]
echo "upload run passed completing its own set on retry after an interruption between passes"

export TEST_GREP
TEST_GREP=$(command -v grep)
cat >"$t/bin/grep" <<'SH'
#!/usr/bin/env bash
if [[ ${!#} == */upload ]]; then
	if { [ "$TEST_FAIL_PASS" = data ] && [ "$1" = -v ]; } \
		|| { [ "$TEST_FAIL_PASS" = narinfo ] && [ "$1" = '\.narinfo$' ]; }; then
		echo "$TEST_FAIL_PASS" >>"$TEST_ROOT/failed-lists"
		exit 2
	fi
fi
exec "$TEST_GREP" "$@"
SH
chmod +x "$t/bin/grep"
failed=false
for pass in data narinfo; do
	export TEST_FAIL_PASS=$pass
	bucket=$t/$pass-bucket
	mkdir -p "$bucket/pending"
	echo '{}' >"$bucket/pending/c1"
	cp "$bucket/pending/c1" "$t/old-pointer"
	jq --arg t "$bucket" '.bucket=$t | .machines.c1.builders={}' "$t/build.json" >"$t/list-failure.json"
	: >"$t/events"
	: >"$t/uploaded"
	: >"$t/failed-lists"
	status=0
	MACHINE_CACHE_CONFIG=$t/list-failure.json bash -euo pipefail "$t/run.sh" c1 --now \
		>"$t/list-failure-log" 2>&1 || status=$?
	if [ "$status" = 2 ] && [ "$(cat "$t/failed-lists")" = "$pass" ] \
		&& [ ! -s "$t/uploaded" ] && [ -z "$(published)" ] \
		&& cmp -s "$t/old-pointer" "$bucket/pending/c1" \
		&& [ "$(tail -n 1 "$t/list-failure-log")" = 'machine-cache outcome=failed consumer=c1' ]; then
		echo "upload run passed refusing all uploads after a $pass list failure"
	else
		echo "upload run failed refusing all uploads after a $pass list failure" >&2
		cat "$t/list-failure-log" >&2
		failed=true
	fi
done
rm "$t/bin/grep"
[ "$failed" = false ]
