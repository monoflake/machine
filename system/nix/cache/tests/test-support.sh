# Cache tests use local keys and a directory bucket with shell command substitutes.
cache_test_tools() {
	if [ -z "${MACHINE_CACHE_TOOLS:-}" ]; then
		local inputs
		inputs=$(mktemp -d)
		trap 'rm -rf "$inputs"' EXIT
		cp "$(dirname "${BASH_SOURCE[0]}")/../../../../"{flake.nix,flake.lock} "$inputs/"
		nix shell --inputs-from "path:$inputs" nixpkgs#coreutils nixpkgs#jq nixpkgs#util-linux \
			-c env MACHINE_CACHE_TOOLS=1 ${TMPDIR:+TMPDIR="$TMPDIR"} bash "$0" "$@"
		exit
	fi
}
cache_test_tools "$@"
setup_test() {
	t=$(mktemp -d)
	export TEST_ROOT=$t TMPDIR=$t
	mkdir -p "$t/bin" "$t/bucket/pending/c1" "$t/state" "$t/work" "$t/hosts/c1" "$t/upstream"
	export CACHE_TEST_DATE
	CACHE_TEST_DATE=$(command -v date)
	date -u -d 2026-10-26T14:00:00Z +%s >"$t/clock"
	export PATH=$t/bin:$PATH
	path=/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system
	ref=/nix/store/1123456789abcdfghijklmnpqrsvwxyz-reference
	echo "$path" >"$t/current"
	echo "$path" >"$t/hosts/c1/current"
	printf '%s\n%s\n' "$path" "$ref" >"$t/closure"
	# Upstream holds the reference and lacks the system, as it lacks what a deployment builds.
	h=${ref##*/}; printf 'StorePath: %s\n' "$ref" >"$t/upstream/${h%%-*}.narinfo"
	: >"$t/events"
	cat >"$t/bin/date" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
	if [ "$a" = -d ]; then exec "$CACHE_TEST_DATE" "$@"; fi
done
exec "$CACHE_TEST_DATE" -u -d "@$(cat "$TEST_ROOT/clock")" "${!#}"
SH
	cat >"$t/bin/readlink" <<'SH'
#!/usr/bin/env bash
cat "$TEST_ROOT/current"
SH
	cat >"$t/bin/ssh" <<'SH'
#!/usr/bin/env bash
host=${@: -2:1}; host=${host#machine-cache@}
command=${!#}
printf '%s %s\n' "$host" "$command" >>"$TEST_ROOT/asked"
cat "$TEST_ROOT/hosts/$host/$command"
SH
	cat >"$t/bin/nix-store" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_ROOT/nix-calls"
[ "$1" != --check-validity ] || [ "${TEST_VALID:-true}" = true ]
SH
	cat >"$t/bin/nix-env" <<'SH'
#!/usr/bin/env bash
echo profile >>"$TEST_ROOT/switched"
SH
	cat >"$t/bin/nix" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_ROOT/build-calls"
case $1 in
build|eval) echo "${TEST_OUTPUT:-$(cat "$TEST_ROOT/current")}" ;;
path-info)
	if [ "$2" = -r ]; then cat "$TEST_ROOT/closure"; exit; fi
	[ "${TEST_UPSTREAM:-up}" = up ] || { echo "error: unable to download '$3/nix-cache-info'" >&2; exit 1; }
	while read -r p; do
		h=${p##*/}; h=${h%%-*}
		dir=${3#file://}; dir=${dir%%\?*}
		if [ -f "$dir/$h.narinfo" ]; then jq -n --arg p "$p" '{($p): {path: $p}}'
		else jq -n --arg p "$p" '{($p): null}'
		fi
	done | jq -s 'add // {}' ;;
copy)
	while [ "$1" != --to ]; do shift; done
	stage=${2#file://}; stage=${stage%%\?*}
	mkdir -p "$stage/nar"
	echo 'StoreDir: /nix/store' >"$stage/nix-cache-info"
	while read -r p; do
		h=${p##*/}; h=${h%%-*}
		printf 'URL: nar/%s.nar.zst\nReferences: \n' "$h" >"$stage/$h.narinfo"
		printf '%080d\n' 0 >"$stage/nar/$h.nar.zst"
	done <"$TEST_ROOT/closure" ;;
*) exit 1 ;;
esac
SH
	# Upstream's answer for one narinfo, 403 where the test forbids it and a redirect where it moves.
	cat >"$t/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_ROOT/curl-calls"
[ "${TEST_UPSTREAM:-up}" = up ] || exit 7
follow=false
while [ "$1" != -w ]; do [ "$1" != -L ] || follow=true; shift; done
format=$2 file=${!#}; file=${file#file://}
code=404
if [ -f "$file.redirect" ]; then
	code=302
	[ "$follow" = false ] || file=$(cat "$file.redirect")
fi
if [ "$code" = 404 ] || [ "$follow" = true ]; then
	code=404
	[ ! -f "$file" ] || code=200
	[ ! -f "$file.forbidden" ] || code=403
fi
printf '%b' "${format//%\{http_code\}/$code}"
SH
	cat >"$t/bin/rclone" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_ROOT/events"
case $1 in
cat)
	if [[ $2 == *.claim ]] && [ -f "$TEST_ROOT/advance-on-claim" ]; then
		cat "$TEST_ROOT/advance-on-claim" >"$TEST_ROOT/clock"
	fi
	cat "$2" 2>/dev/null || true ;;
copyto)
	[ "$2" != --no-check-dest ] || shift
	if [[ $3 == *.sig ]]; then
		[ ! -f "${3%.sig}" ] || { echo "old pointer paired with new signature" >&2; exit 1; }
	fi
	mkdir -p "$(dirname "$3")"; cp "$2" "$3" ;;
deletefile) [ -f "$2" ] || exit 9; rm -f "$2" ;;
size)
	# Every regular file's bytes, as rclone sizes a local remote.
	[ "$2 $3" = "--fast-list --json" ] || exit 1
	find "$4" -type f -exec stat -c %s {} + | jq -s '{count: length, bytes: add // 0, sizeless: 0}' ;;
copy)
	# The run's uploads neither list nor compare the bucket, docs/cache.md.
	all=$*
	[[ $all == *' --no-check-dest '* ]] || { echo "copy compares the destination" >&2; exit 1; }
	list=${all#*--files-from-raw }; list=${list%% *}
	while read -r f; do
		mkdir -p "${!#}/$(dirname "$f")"
		cp "${@: -2:1}/$f" "${!#}/$f"
		echo "$f" >>"$TEST_ROOT/uploaded"
	done <"$list" ;;
*) exit 1 ;;
esac
SH
	chmod +x "$t/bin/"*
	for b in a1 a2; do
		ssh-keygen -q -t ed25519 -N '' -C example.com -f "$t/$b"
		printf 'builder namespaces="machine-cache" %s\n' "$(cat "$t/$b.pub")" >"$t/$b.signers"
	done
	cat "$t/a1.signers" "$t/a2.signers" >"$t/signers"
	jq -n --arg t "$t" '{bucket:($t+"/bucket"),machine:"c1",substituters:"https://example.com/upstream",trusted:"example.com:key example.com-upstream:key",signers:($t+"/signers"),builders:[{name:"a1",signers:($t+"/a1.signers")},{name:"a2",signers:($t+"/a2.signers")}]}' >"$t/fetch.json"
	jq -n --arg t "$t" '{builder:"a1",bucket:($t+"/bucket"),upstream:("file://"+$t+"/upstream"),cap:5000000000,store:null,pointerKey:($t+"/a1"),signingKey:($t+"/a1"),accessKey:($t+"/a1"),tailnet:false,machines:{c1:{flake:"https://example.com/machines",host:"c1",builders:{a1:1,a2:1},slots:["14:00","14:20"],gap:20}}}' >"$t/build.json"
	export MACHINE_CACHE_CONFIG=$t/fetch.json MACHINE_CACHE_APPLIED=$t/state/applied MACHINE_CACHE_STARTED=$t/state/started
	export MACHINE_CACHE_STATE=$t/state MACHINE_CACHE_LOCK=$t/lock
	cat "$cache_dir/../protocol.sh" "$cache_dir/../run.sh" >"$t/run.sh"
}
fail() { echo "$*" >&2; exit 1; }
clock_at() { "$CACHE_TEST_DATE" -u -d "$1" +%s >"$t/clock"; }
pointer() {
	local b=$1 at=$2 machine=${3:-c1} prefix
	prefix=$t/bucket/pending/$machine/$b
	mkdir -p "$(dirname "$prefix")"
	jq -n --arg path "$path" --arg at "$at" --arg machine "$machine" '{machine:$machine,path:$path,at:$at}' >"$prefix"
	rm -f "$prefix.sig"
	ssh-keygen -q -Y sign -f "$t/$b" -n machine-cache "$prefix"
}
fetch_test() { bash -euo pipefail -c 'source "$1/protocol.sh"; source "$1/fetch.sh"' _ "$cache_dir/.."; }
run_test() { MACHINE_CACHE_CONFIG=$t/build.json bash -euo pipefail "$t/run.sh" c1 "${@}"; }
