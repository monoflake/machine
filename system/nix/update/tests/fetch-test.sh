#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
if [ "${UPDATE_TEST_TOOLS:-}" != 1 ]; then
	inputs=$(realpath "$(mktemp -d)")
	trap 'rm -rf "$inputs"' EXIT
	cp "$here/../../../../"{flake.nix,flake.lock} "$inputs/"
	nix shell --inputs-from "path:$inputs" nixpkgs#coreutils nixpkgs#jq nixpkgs#gawk \
		-c env UPDATE_TEST_TOOLS=1 bash "$0"
	exit
fi
t=$(realpath "$(mktemp -d)")
trap 'rm -rf "$t"' EXIT
export TEST_ROOT=$t STATE_DIRECTORY=$t/state MACHINE_UPDATE_CONFIG=$t/config
mkdir -p "$t/bin" "$t/state" "$t/bucket/pointer/system"
export PATH=$t/bin:$PATH
export UPDATE_TEST_DATE
UPDATE_TEST_DATE=$(command -v date)
path=/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system
old=/nix/store/1123456789abcdfghijklmnpqrsvwxyz-system
printf '%s\n' "$old" >"$t/current"
printf '%s\n' "$old" >"$t/profile"
openssl rand -hex 16 >"$t/access"
openssl rand -hex 32 >"$t/secret"
printf '[other]\naws_access_key_id = ignored\n[systems]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
	"$(cat "$t/access")" "$(cat "$t/secret")" >"$t/credentials"
export AWS_SHARED_CREDENTIALS_FILE=$t/credentials
printf 'https://%s.invalid\n' "$(openssl rand -hex 16)" >"$t/endpoint"
ssh-keygen -q -t ed25519 -N '' -C '' -f "$t/key"
printf 'ci namespaces="system-pointer" %s\n' "$(cat "$t/key.pub")" >"$t/signers"
jq -n --arg t "$t" '{machine:"c1",bucket:("file://"+$t+"/bucket"),credentialsFile:($t+"/credentials"),endpointFile:($t+"/endpoint"),signers:($t+"/signers"),trusted:"fixture"}' >"$t/config"
cat >"$t/bin/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = '-u +%s' ]; then exec "$UPDATE_TEST_DATE" -u -d 2026-10-29T14:00:00Z +%s; fi
exec "$UPDATE_TEST_DATE" "$@"
SH
cat >"$t/bin/readlink" <<'SH'
#!/usr/bin/env bash
[ "$1" = /run/current-system ]
cat "$TEST_ROOT/current"
SH
cat >"$t/bin/nix-store" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$TEST_ROOT/realise-args"
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
	if [ "${args[i]}" = --option ]; then
		case ${args[i+1]} in
		max-jobs) [ "${args[i+2]}" = 0 ]; jobs=zero ;;
		builders) [ -z "${args[i+2]}" ]; builders=none ;;
		require-sigs) [ "${args[i+2]}" = true ]; signatures=yes ;;
		esac
	fi
done
[ "$jobs $builders $signatures" = 'zero none yes' ]
if [ -f "$TEST_ROOT/missing" ]; then
	cat "$TEST_ROOT/endpoint" "$TEST_ROOT/credentials" >&2
	exit 1
fi
SH
cat >"$t/bin/nix-env" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ ! -f "$TEST_ROOT/profile-fail" ] || exit 1
printf '%s\n' "${!#}" >"$TEST_ROOT/profile"
SH
cat >"$t/bin/switch-to-configuration" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$TEST_ROOT/switches"
if [ "$1" != "$(cat "$TEST_ROOT/original")" ] && [ -f "$TEST_ROOT/switch-fail" ]; then
	cat "$TEST_ROOT/endpoint" "$TEST_ROOT/credentials" >&2
	exit 1
fi
printf '%s\n' "$1" >"$TEST_ROOT/current"
SH
chmod +x "$t/bin/"*
printf '%s\n' "$old" >"$t/original"
# Functions stand in for the absolute switch commands without writing to the store.
eval "function $path/bin/switch-to-configuration() { switch-to-configuration '$path' \"\$@\"; }"
eval "function $old/bin/switch-to-configuration() { switch-to-configuration '$old' \"\$@\"; }"
pointer() {
	jq -n --arg path "$path" --arg at "${1:-2026-10-29T13:00:00Z}" --arg run "${2:-1}" \
		'{machine:"c1",path:$path,at:$at,run:$run}' >"$t/bucket/pointer/system/c1"
}
sign() {
	rm -f "$t/bucket/pointer/system/c1.sig"
	ssh-keygen -q -Y sign -f "$t/key" -n "${1:-system-pointer}" "$t/bucket/pointer/system/c1"
}
fetch() (
	set -euo pipefail
	. "$here/../protocol.sh"
	. "$here/../fetch.sh"
)
run_fetch() {
	local status=0
	fetch "$@" >"$t/output" 2>&1 || status=$?
	cat "$t/output" >>"$t/all-output"
	return "$status"
}
refused() {
	if run_fetch; then
		echo 'invalid pointer accepted' >&2
		exit 1
	fi
	cat "$t/output" >>"$t/all-output"
	grep -q "$1" "$t/output"
	cmp "$t/state/accepted.json" "$t/accepted"
	[ "$(cat "$t/current")" = "$old" ]
	[ "$(cat "$t/profile")" = "$old" ]
}
pointer
sign
run_fetch --dry-run
[ ! -f "$t/state/accepted.json" ]
[ ! -f "$t/realise-args" ]
[ ! -f "$t/switches" ]
grep -q 'would switch' "$t/output"
run_fetch
[ "$(cat "$t/current")" = "$path" ]
[ "$(cat "$t/profile")" = "$path" ]
jq -e --arg path "$path" '.path == $path and .run == "1"' "$t/state/accepted.json" >/dev/null
cp "$t/state/accepted.json" "$t/accepted"
cp "$t/realise-args" "$t/saved-args"
run_fetch
[ "$(wc -l <"$t/switches")" = 1 ]
cmp "$t/realise-args" "$t/saved-args"
grep -q 'running system' "$t/output"
run_fetch --dry-run
cmp "$t/state/accepted.json" "$t/accepted"
rm "$t/state/accepted.json"
run_fetch
cmp "$t/state/accepted.json" "$t/accepted"
[ "$(wc -l <"$t/switches")" = 1 ]
printf '%s\n' "$old" >"$t/current"
printf '%s\n' "$old" >"$t/profile"
run_fetch
grep -q 'would not switch again' "$t/output"
[ "$(wc -l <"$t/switches")" = 1 ]
cmp "$t/state/accepted.json" "$t/accepted"
printf broken >"$t/bucket/pointer/system/c1.sig"
refused 'invalid system-pointer signature'
sign driver-pointer
refused 'invalid system-pointer signature'
ssh-keygen -q -t ed25519 -N '' -C '' -f "$t/mac"
printf 'mac namespaces="driver-pointer" %s\n' "$(cat "$t/mac.pub")" >>"$t/signers"
rm "$t/bucket/pointer/system/c1.sig"
ssh-keygen -q -Y sign -f "$t/mac" -n system-pointer "$t/bucket/pointer/system/c1"
refused 'invalid system-pointer signature'

for mutation in '.machine="c2"' '.path="/tmp/system"' '.at="tomorrow"' '.at="2026-02-30T12:00:00Z"' '.at="2026-10-29T15:00:01Z"' '.run=""' '.run="line\nfeed"' '.extra="value"'; do
	pointer
	jq "$mutation" "$t/bucket/pointer/system/c1" >"$t/changed"
	mv "$t/changed" "$t/bucket/pointer/system/c1"
	sign
	case $mutation in
	*machine*) reason='another machine' ;;
	*path*) reason='malformed path' ;;
	*15:00*) reason='one hour ahead' ;;
	*at*) reason='malformed time' ;;
	*run*) reason='malformed run' ;;
	*) reason='malformed pointer fields' ;;
	esac
	refused "$reason"
done
pointer 2026-10-29T12:59:59Z
sign
refused 'older at'
pointer 2026-10-29T13:00:00Z 2
sign
refused 'equal at from another run'
pointer 2026-10-29T13:01:00Z 2
sign
touch "$t/missing"
refused 'realise failed'
rm "$t/missing"
touch "$t/profile-fail"
refused 'profile update failed'
rm "$t/profile-fail"
touch "$t/switch-fail"
refused 'switch failed'
rm "$t/switch-fail"
run_fetch --dry-run
cmp "$t/state/accepted.json" "$t/accepted"
[ "$(cat "$t/current")" = "$old" ]
[ "$(cat "$t/profile")" = "$old" ]
rm "$t/bucket/pointer/system/c1.sig"
refused 'signature fetch failed'
sign
rm "$t/bucket/pointer/system/c1"
refused 'pointer fetch failed'
for value in access secret endpoint key.pub; do
	if grep -Fq "$(cat "$t/$value")" "$t/all-output"; then
		echo 'runtime access value leaked' >&2
		exit 1
	fi
done
awk 'index($0, "update:") != 1 { exit 1 }' "$t/all-output"
echo 'update fetch: switch, same system, signature namespaces, fields, rollback, no builds, failures, dry run and private output passed'
