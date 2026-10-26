#!/usr/bin/env bash
# Self publication follows its objects and survives a sweep without repeating an upload.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")/.." && pwd)
. "$cache_dir/test-support.sh"
setup_test
trap 'rm -rf "$t"' EXIT
cat >"$t/switch" <<'SH'
function /nix/store/0123456789abcdfghijklmnpqrsvwxyz-system/bin/switch-to-configuration {
	echo switch >>"$TEST_ROOT/switched"
}
SH
cat "$t/switch" "$t/run.sh" >"$t/self-run.sh"
jq '.self="build" | .fetch=null | .machines={a1:.machines.c1}' "$t/build.json" >"$t/self.json"
export MACHINE_CACHE_CONFIG=$t/self.json
cat >"$t/bin/nix" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_ROOT/build-calls"
case $1 in
build|eval) cat "$TEST_ROOT/current" ;;
path-info)
	if [ "$2" = -r ]; then cat "$TEST_ROOT/closure"
	else
		store=${3#file://}; p=${4##*/}; h=${p%%-*}
		[ -f "$store/$h.narinfo" ]
	fi ;;
copy)
	while [ "$1" != --to ]; do shift; done
	stage=${2#file://}; stage=${stage%%\?*}
	mkdir -p "$stage/nar"
	echo 'StoreDir: /nix/store' >"$stage/nix-cache-info"
	while read -r p; do
		h=${p##*/}; h=${h%%-*}
		refs=""
		if [ "$p" = "$(cat "$TEST_ROOT/current")" ]; then
			refs=$(tail -n 1 "$TEST_ROOT/closure"); refs=${refs##*/}
		fi
		printf 'URL: nar/%s.nar.zst\nReferences: %s\n' "$h" "$refs" >"$stage/$h.narinfo"
		printf '%080d\n' 0 >"$stage/nar/$h.nar.zst"
	done <"$TEST_ROOT/closure" ;;
*) exit 1 ;;
esac
SH

mv "$t/bin/rclone" "$t/bin/rclone-original"
cat >"$t/bin/rclone" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = copy ] && [ -f "$TEST_ROOT/interrupt-upload" ]; then
	if grep -q '\.narinfo$' "$4"; then
		if grep -qv '\.narinfo$' "$4"; then
			while read -r f; do
				[[ $f == *.narinfo ]] || continue
				cp "${@: -2:1}/$f" "${!#}/$f"
			done <"$4"
		fi
		exit 7
	fi
fi
if [ "$1" = cat ] && [ "$2" = "${TEST_UNREADABLE:-}" ]; then exit 7; fi
exec "$TEST_ROOT/bin/rclone-original" "$@"
SH
chmod +x "$t/bin/rclone"
bash -euo pipefail "$t/self-run.sh" a1 --self
jq -e --arg p "$path" 'keys == ["at","path"] and .path == $p and .at == "2026-10-26T14:00:00Z"' \
	"$t/bucket/self/a1" >/dev/null
[ "$(cat "$t/switched")" = "profile
switch" ]
[[ $(tail -n 1 "$t/events") == "copyto "*" $t/bucket/self/a1" ]]
[ "$(wc -l <"$t/uploaded" | tr -d ' ')" = 5 ]
[ ! -f "$t/bucket/pending/a1/a1" ] && [ ! -f "$t/bucket/pending/a1/a1.objects" ]
find "$t/bucket" -type f -exec touch -d 2026-10-25T10:00:00Z {} +
snapshot() {
	(cd "$t/bucket" && find . -type f ! -path './self/*' | sort | while read -r o; do
		stat -c '%n %s %Y' "$o"
		sha256sum "$o"
	done)
}
snapshot >"$t/before"
clock_at 2026-10-27T14:00:00Z
: >"$t/uploaded"
: >"$t/events"
bash -euo pipefail "$t/self-run.sh" a1 --self
[ ! -s "$t/uploaded" ]
! grep -q '^copy ' "$t/events"
! grep -q '^deletefile ' "$t/events"
snapshot >"$t/after"
cmp "$t/before" "$t/after"
[ "$(jq -r .at "$t/bucket/self/a1")" = 2026-10-27T14:00:00Z ]
echo "self marker run passed publication order and an unchanged closure with no upload after a daily sweep"

jq --arg t "$t" '.bucket=($t+"/retry-bucket")' "$t/self.json" >"$t/retry.json"
touch "$t/interrupt-upload"
status=0
MACHINE_CACHE_CONFIG=$t/retry.json bash -euo pipefail "$t/self-run.sh" a1 --self \
	>"$t/interrupted-log" 2>&1 || status=$?
[ "$status" = 7 ]
[ ! -f "$t/retry-bucket/self/a1" ]
find "$t/retry-bucket" -type f >"$t/interrupted-objects"
rm "$t/interrupt-upload"
find "$t/retry-bucket" -type f -exec touch -d 2026-10-27T14:00:00Z {} +
MACHINE_CACHE_CONFIG=$t/retry.json bash -euo pipefail "$t/self-run.sh" a1 --self
for p in "$path" "$ref"; do
	h=${p##*/}; h=${h%%-*}
	[ -f "$t/retry-bucket/$h.narinfo" ]
	[ -f "$t/retry-bucket/nar/$h.nar.zst" ]
	grep -qxF "$t/retry-bucket/nar/$h.nar.zst" "$t/interrupted-objects"
done
! grep -q '\.narinfo$' "$t/interrupted-objects"
[ "$(jq -r .path "$t/retry-bucket/self/a1")" = "$path" ]
echo "self marker run passed completing the closure on retry after interruption between upload passes"

for unreadable in self/a1 1123456789abcdfghijklmnpqrsvwxyz.narinfo; do
	export TEST_UNREADABLE=$t/bucket/$unreadable
	rm "$t/bucket/nix-cache-info"
	: >"$t/uploaded"
	: >"$t/build-calls"
	: >"$t/events"
	status=0
	bash -euo pipefail "$t/self-run.sh" a1 --self >"$t/refused-log" 2>"$t/refused-errors" || status=$?
	[ "$status" = 1 ]
	grep -q '^build ' "$t/build-calls"
	grep -qx nix-cache-info "$t/uploaded"
	! grep -q '^deletefile ' "$t/events"
	grep -q 'sweep refused' "$t/refused-errors"
	grep -qF "$unreadable" "$t/refused-errors"
	[ "$(grep -c '^machine-cache outcome=' "$t/refused-log")" = 1 ]
	[ "$(tail -n 1 "$t/refused-log")" = 'machine-cache outcome=built consumer=a1 self=built' ]
	echo "self marker run passed building and uploading with a visible sweep refusal for $unreadable"
done
unset TEST_UNREADABLE

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
echo "$ref" >"$t/hosts/c1/current"
for scenario in self-data self-narinfo consumer-data consumer-narinfo; do
	pass=${scenario#*-}
	export TEST_FAIL_PASS=$pass
	bucket=$t/$scenario-bucket
	mkdir -p "$bucket/self" "$bucket/pending"
	echo '{}' >"$bucket/self/a1"
	echo '{}' >"$bucket/pending/c1"
	cp "$bucket/self/a1" "$t/old-marker"
	cp "$bucket/pending/c1" "$t/old-pointer"
	if [[ $scenario == self-* ]]; then
		jq --arg t "$bucket" '.bucket=$t' "$t/self.json" >"$t/list-failure.json"
		args=(a1 --self)
		expected='machine-cache outcome=failed consumer=a1 self=built'
	else
		jq --arg t "$bucket" '.bucket=$t | .machines.c1.builders={}' \
			"$t/build.json" >"$t/list-failure.json"
		args=(c1 --now)
		expected='machine-cache outcome=failed consumer=c1'
	fi
	: >"$t/events"
	: >"$t/uploaded"
	: >"$t/failed-lists"
	status=0
	MACHINE_CACHE_CONFIG=$t/list-failure.json bash -euo pipefail "$t/self-run.sh" "${args[@]}" \
		>"$t/list-failure-log" 2>&1 || status=$?
	if [ "$status" = 2 ] && [ "$(cat "$t/failed-lists")" = "$pass" ] \
		&& [ ! -s "$t/uploaded" ] && ! grep -qE '^copy(to)? ' "$t/events" \
		&& cmp -s "$t/old-marker" "$bucket/self/a1" && cmp -s "$t/old-pointer" "$bucket/pending/c1" \
		&& [ "$(tail -n 1 "$t/list-failure-log")" = "$expected" ]; then
		echo "cache run passed refusing all uploads after $scenario list failure"
	else
		echo "cache run failed refusing all uploads after $scenario list failure" >&2
		cat "$t/list-failure-log" >&2
		failed=true
	fi
done
rm "$t/bin/grep"
unset TEST_FAIL_PASS
[ "$failed" = false ]

cp "$t/bucket/self/a1" "$t/previous"
cat >"$t/bin/fetch-command" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$t/bin/fetch-command"
jq --arg t "$t" '.self="cache" | .fetch={command:($t+"/bin/fetch-command"),config:"unused"}' \
	"$t/self.json" >"$t/fetched.json"
: >"$t/events"
MACHINE_CACHE_CONFIG=$t/fetched.json bash -euo pipefail "$t/self-run.sh" a1 --self
cmp "$t/previous" "$t/bucket/self/a1"
[ ! -s "$t/events" ]

cat >"$t/bin/rclone" <<'SH'
#!/usr/bin/env bash
if [ "$1" = copy ]; then exit 7; fi
exec "$TEST_ROOT/bin/rclone-original" "$@"
SH
chmod +x "$t/bin/rclone"
rm "$t/bucket/0123456789abcdfghijklmnpqrsvwxyz.narinfo"
status=0
bash -euo pipefail "$t/self-run.sh" a1 --self >"$t/failed-log" 2>&1 || status=$?
[ "$status" = 7 ]
cmp "$t/previous" "$t/bucket/self/a1"
echo "self marker run passed preserving the previous marker after a fetch or failed upload"
