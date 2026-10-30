#!/usr/bin/env bash
set -euo pipefail
trap 'echo "driver test failed at line $LINENO" >&2; if [ -f "${t:-}/output" ]; then grep -E "^update: (refused|fetching|validating|checking|unpacking|downloading|switching|restarting|reading|verifying)" "$t/output" >&2; fi' ERR
here=$(cd "$(dirname "$0")" && pwd)
if [ "${UPDATE_TEST_TOOLS:-}" != 1 ]; then
	inputs=$(realpath "$(mktemp -d)")
	trap 'rm -rf "$inputs"' EXIT
	cp "$here/../../../../"{flake.nix,flake.lock} "$inputs/"
	nix shell --inputs-from "path:$inputs" nixpkgs#coreutils nixpkgs#jq nixpkgs#gawk nixpkgs#gnutar nixpkgs#util-linux \
		-c env UPDATE_TEST_TOOLS=1 bash "$0"
	exit
fi
t=$(realpath "$(mktemp -d)")
trap 'rm -rf "$t"' EXIT
export TEST_ROOT=$t STATE_DIRECTORY=$t/state MACHINE_UPDATE_CONFIG=$t/config
mkdir -p "$t/bucket/build/driver" "$t/bin" "$t/state" "$t/driver" "$t/bucket/pointer/driver" "$t/release"
export PATH=$t/bin:$PATH AWS_SHARED_CREDENTIALS_FILE=$t/credentials
openssl rand -hex 16 >"$t/access"
openssl rand -hex 32 >"$t/secret"
printf '[systems]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
	"$(cat "$t/access")" "$(cat "$t/secret")" >"$t/credentials"
printf 'https://%s.invalid\n' "$(openssl rand -hex 16)" >"$t/endpoint"
ssh-keygen -q -t ed25519 -N '' -C '' -f "$t/key"
ssh-keygen -q -t ed25519 -N '' -C '' -f "$t/mac"
printf 'ci namespaces="driver-pointer" %s\n' "$(cat "$t/key.pub")" >"$t/signers"
jq -n --arg t "$t" '{machine:"c1",bucket:("file://"+$t+"/bucket"),credentialsFile:($t+"/credentials"),endpointFile:($t+"/endpoint"),driverSigners:($t+"/signers"),driverChannel:true,driverBuilds:false,architecture:"x86_64-linux"}' >"$t/config"
printf '#!/bin/sh\nexit 0\n' >"$t/release/driver-machine"
chmod 0755 "$t/release/driver-machine"
tar -czf "$t/archive" -C "$t/release" driver-machine
cat >"$t/bin/curl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ $* == *--aws-sigv4* ]]; then
	cat >/dev/null
	while [ "$1" != --output ]; do shift; done
	output=$2
	url=${!#}
	object=${url#"$(cat "$TEST_ROOT/endpoint")/fixture/"}
	[ "$object" != "$url" ]
	status=$(cat "$TEST_ROOT/http-status")
	if [[ $object == *.sig ]] && [ -f "$TEST_ROOT/signature-status" ]; then
		status=$(cat "$TEST_ROOT/signature-status")
	fi
	case $status in
	network) exit 7 ;;
	200) cp "$TEST_ROOT/bucket/$object" "$output" ;;
	404|403|500) ;;
	*) exit 1 ;;
	esac
	printf '%s' "$status"
	exit 0
fi
printf '%s\n' "$@" >>"$TEST_ROOT/curl-args"
[[ $* == "--silent --show-error --fail --location --proto =https --proto-redir =https --output "* ]]
while [ "$1" != --output ]; do shift; done
output=$2
url=$3
[ "$url" = "$(cat "$TEST_ROOT/endpoint")/archive" ]
# The transport fixture is local and receives no bucket credentials.
exec /usr/bin/curl --silent --fail --output "$output" "file://$TEST_ROOT/archive"
SHIM
cat >"$t/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$TEST_ROOT/calls"
case $1 in
restart)
	[ "$*" = 'restart driver-machine.service driver-machine-entry.service' ]
	if [ -f "$TEST_ROOT/fail" ]; then
		rm "$TEST_ROOT/fail"
		cat "$TEST_ROOT/endpoint" "$TEST_ROOT/credentials" >&2
		exit 1
	fi ;;
stop) [ "$*" = 'stop driver-machine.service driver-machine-entry.service' ] ;;
is-active) [ "$2" = --quiet ]; [ -x "$TEST_ROOT/driver/current/driver-machine" ] ;;
*) exit 1 ;;
esac
SHIM
cat >"$t/bin/id" <<'SHIM'
#!/usr/bin/env bash
[ "$*" = -u ]
echo 0
SHIM
chmod +x "$t/bin/"*
# Absolute production paths are redirected only in the sourced test copy.
sed "s|/var/lib/driver|$t/driver|g" "$here/../driver.sh" >"$t/driver.sh"
sed "s|/var/lib/driver|$t/driver|g" "$here/../rollback.sh" >"$t/rollback.sh"
fetch() (
	set -euo pipefail
	. "$here/../protocol.sh"
	. "$here/../driver-protocol.sh"
	. "$here/../driver-links.sh"
	. "$t/driver.sh"
	. "$here/../fetch.sh"
)
pointer() {
	jq -n --arg version "$1" --arg at "2026-10-29T13:0${2}:00Z" --arg run "$2" \
		--arg url "$(cat "$t/endpoint")/archive" --arg sha "$(sha256sum "$t/archive" | cut -d ' ' -f 1)" \
		'{machine:"c1",version:$version,at:$at,run:$run,archives:{"x86_64-linux":{url:$url,sha256:$sha},"aarch64-linux":{url:$url,sha256:$sha}}}' >"$t/bucket/pointer/driver/c1"
}
sign() {
	rm -f "$t/bucket/pointer/driver/c1.sig"
	ssh-keygen -q -Y sign -f "$t/${2:-key}" -n "${1:-driver-pointer}" "$t/bucket/pointer/driver/c1"
}
run_fetch() {
	local status=0
	fetch driver "$@" >"$t/output" 2>&1 || status=$?
	cat "$t/output" >>"$t/all-output"
	return "$status"
}
snapshot() {
	find "$t/driver" "$t/state" -exec sh -c 'for path; do printf "%s %s\n" "$path" "$(readlink "$path" || true)"; done' sh '{}' + | sort >"$t/tree"
	find "$t/driver" "$t/state" -type f -exec sha256sum '{}' + | sort >"$t/hashes"
}
unchanged() {
	find "$t/driver" "$t/state" -exec sh -c 'for path; do printf "%s %s\n" "$path" "$(readlink "$path" || true)"; done' sh '{}' + | sort >"$t/after-tree"
	find "$t/driver" "$t/state" -type f -exec sha256sum '{}' + | sort >"$t/after-hashes"
	cmp "$t/tree" "$t/after-tree"
	cmp "$t/hashes" "$t/after-hashes"
}
refused() {
	if run_fetch; then echo 'invalid driver pointer accepted' >&2; exit 1; fi
	grep -q "$1" "$t/output"
	cmp "$t/accepted" "$t/state/accepted.json"
	[ "$(readlink "$t/driver/current")" = 1.0 ]
}
configure() {
	jq "$1" "$t/config" >"$t/changed-config"
	mv "$t/changed-config" "$t/config"
}
pointer 1.0 0
sign
snapshot
run_fetch --dry-run
unchanged
[ ! -f "$t/calls" ]
[ ! -f "$t/curl-args" ]
grep -q 'would install' "$t/output"
ln -s stale "$t/driver/previous"
touch "$t/fail"
if run_fetch; then echo 'failed first install accepted' >&2; exit 1; fi
grep -q '^update: refused, driver restart failed$' "$t/output"
! grep -q 'restoration failed' "$t/output"
[ ! -L "$t/driver/current" ]
[ ! -L "$t/driver/previous" ]
[ ! -f "$t/state/accepted.json" ]
printf '%s\n' 'restart driver-machine.service driver-machine-entry.service' \
	'stop driver-machine.service driver-machine-entry.service' >"$t/expected-calls"
cmp "$t/expected-calls" "$t/calls"
run_fetch
[ "$(readlink "$t/driver/current")" = 1.0 ]
[ ! -e "$t/driver/previous" ]
[ "$(stat -c %a "$t/driver/1.0")" = 755 ]
[ "$(stat -c %a "$t/driver/1.0/driver-machine")" = 755 ]
cp "$t/state/accepted.json" "$t/accepted"
cp "$t/calls" "$t/saved-calls"
run_fetch
cmp "$t/calls" "$t/saved-calls"
grep -q 'already taken' "$t/output"
pointer 1.0 1
sign
run_fetch
cmp "$t/calls" "$t/saved-calls"
grep -q 'running driver' "$t/output"
cp "$t/state/accepted.json" "$t/accepted"
snapshot
for object in c1 c1.sig; do
	mv "$t/bucket/pointer/driver/$object" "$t/missing-object"
	run_fetch
	grep -q '^update: no driver pointer, nothing to do$' "$t/output"
	unchanged
	mv "$t/missing-object" "$t/bucket/pointer/driver/$object"
done
configure '.bucket="fixture"'
for status in 404 403 500 network; do
	printf '%s' "$status" >"$t/http-status"
	if [ "$status" = 404 ]; then
		run_fetch
		grep -q '^update: no driver pointer, nothing to do$' "$t/output"
	else
		refused 'pointer fetch failed'
	fi
	unchanged
done
printf 200 >"$t/http-status"
for status in 404 403 500 network; do
	printf '%s' "$status" >"$t/signature-status"
	if [ "$status" = 404 ]; then
		run_fetch
		grep -q '^update: no driver pointer, nothing to do$' "$t/output"
	else
		refused 'signature fetch failed'
	fi
	unchanged
done
rm "$t/signature-status"
run_fetch
grep -q 'already taken' "$t/output"
jq --arg bucket "file://$t/bucket" '.bucket=$bucket' "$t/config" >"$t/changed-config"
mv "$t/changed-config" "$t/config"
printf broken >"$t/bucket/pointer/driver/c1.sig"
refused 'invalid driver-pointer signature'
sign system-pointer
refused 'invalid driver-pointer signature'
sign driver-pointer mac
refused 'invalid driver-pointer signature'
printf 'mac namespaces="driver-pointer" %s\n' "$(cat "$t/mac.pub")" >>"$t/signers"
pointer 1.0 1
sign driver-pointer mac
run_fetch
grep -q 'already taken' "$t/output"

for mutation in '.archives["x86_64-linux"].url=("build/driver/"+("0"*64)+".tar.gz")' '.machine="c2"' '.archives["x86_64-linux"].sha256=("0"*64)' '.archives["x86_64-linux"].url="file:///archive"' '.version=".."' '.at="2026-02-30T12:00:00Z"' '.at="2099-01-01T00:00:00Z"' '.run=""' '.extra=true' '.archives.extra={}' '.archives["aarch64-linux"].extra=true'; do
	pointer 2.0 2
	jq "$mutation" "$t/bucket/pointer/driver/c1" >"$t/changed"
	mv "$t/changed" "$t/bucket/pointer/driver/c1"
	sign
	refused 'refused'
done
pointer 2.0 0
sign
refused 'older at'
pointer 2.0 1
sign
refused 'accepted run changed pointer'
jq '.run="other"' "$t/bucket/pointer/driver/c1" >"$t/changed"
mv "$t/changed" "$t/bucket/pointer/driver/c1"
sign
refused 'equal at from another run'
cp "$t/archive" "$t/good-archive"
echo fixture >"$t/release/LICENSE-MIT"
tar -czf "$t/archive" -C "$t/release" LICENSE-MIT
pointer 2.0 2
sign
refused 'archive lacks executable'
cp "$t/good-archive" "$t/archive"
pointer 2.0 2
sign
touch "$t/fail"
refused 'driver restart failed'
[ ! -e "$t/driver/previous" ]
snapshot
run_fetch --dry-run
unchanged
run_fetch
pointer 3.0 3
sha=$(sha256sum "$t/archive" | cut -d ' ' -f 1)
cp "$t/archive" "$t/bucket/build/driver/$sha.tar.gz"
jq --arg url "build/driver/$sha.tar.gz" '.archives |= map_values(.url=$url)' \
	"$t/bucket/pointer/driver/c1" >"$t/changed"
mv "$t/changed" "$t/bucket/pointer/driver/c1"
for signer in key mac; do
	sign driver-pointer "$signer"
	snapshot
	cp "$t/curl-args" "$t/saved-curl-args"
	if run_fetch; then echo 'build archive accepted without permission' >&2; exit 1; fi
	grep -q 'build archives not allowed on this machine' "$t/output"
	unchanged
	cmp "$t/curl-args" "$t/saved-curl-args"
done
configure '.driverBuilds=true'
snapshot
mv "$t/bucket/build/driver/$sha.tar.gz" "$t/expired-archive"
if run_fetch; then echo 'expired build accepted' >&2; exit 1; fi
grep -q 'archive download failed' "$t/output"
unchanged
mv "$t/expired-archive" "$t/bucket/build/driver/$sha.tar.gz"
run_fetch
[ "$(readlink "$t/driver/current")" = 3.0 ]
[ "$(readlink "$t/driver/previous")" = 2.0 ]
[ ! -d "$t/driver/1.0" ]
[ "$(find "$t/driver" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 2 ]
cp "$t/state/accepted.json" "$t/accepted"
rm "$t/bucket/build/driver/$sha.tar.gz"
snapshot
run_fetch
unchanged
for object in c1 c1.sig; do
	mv "$t/bucket/pointer/driver/$object" "$t/missing-object"
	run_fetch
	grep -q '^update: no driver pointer, nothing to do$' "$t/output"
	unchanged
	mv "$t/missing-object" "$t/bucket/pointer/driver/$object"
done
(
	. "$here/../driver-links.sh"
	. "$t/rollback.sh"
) >"$t/output" 2>&1
cat "$t/output" >>"$t/all-output"
grep -q 'rolled driver back to 2.0' "$t/output"
[ "$(readlink "$t/driver/current")" = 2.0 ]
[ "$(readlink "$t/driver/previous")" = 3.0 ]
cmp "$t/accepted" "$t/state/accepted.json"
run_fetch
[ "$(readlink "$t/driver/current")" = 2.0 ]
# A newer pointer may deliberately select an older release.
pointer .1.0 4
sign
run_fetch
[ "$(readlink "$t/driver/current")" = .1.0 ]
[ "$(readlink "$t/driver/previous")" = 2.0 ]
[ ! -d "$t/driver/3.0" ]
pointer 2.0 5
sign
run_fetch
pointer 3.0 6
sign
run_fetch
[ ! -d "$t/driver/.1.0" ]
[ "$(readlink "$t/driver/previous")" = 2.0 ]
for value in access secret endpoint key.pub mac.pub; do
	if grep -Fq "$(cat "$t/$value")" "$t/all-output"; then
		echo 'runtime access value leaked' >&2
		exit 1
	fi
done
awk 'index($0, "update:") != 1 { exit 1 }' "$t/all-output"
echo 'driver fetch: install, same version, CI and Mac signers, namespaces, build guard, expired builds, absent pointers, transport failures, first install recovery, validation, hash, rollback, retention, dry run and private output passed'
