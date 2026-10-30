#!/usr/bin/env bash
# A fetched or already valid system survives a real store's collection until the profile holds it,
# docs/store.md.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${MACHINE_CACHE_STORE_TOOLS:-}" ]; then
	inputs=$(realpath "$(mktemp -d)")
	trap 'rm -rf "$inputs"' EXIT
	cp "$cache_dir/../../../../"{flake.nix,flake.lock} "$inputs/"
	nix shell --inputs-from "path:$inputs" nixpkgs#nix nixpkgs#coreutils nixpkgs#jq \
		-c env MACHINE_CACHE_STORE_TOOLS=1 MACHINE_CACHE_TOOLS=1 ${TMPDIR:+TMPDIR="$TMPDIR"} \
		bash "$0" "$@"
	exit
fi
export CACHE_TEST_NIX
CACHE_TEST_NIX=$(command -v nix)
export CACHE_TEST_NIX_STORE=${CACHE_TEST_NIX%/*}/nix-store
export CACHE_TEST_NIX_ENV=${CACHE_TEST_NIX%/*}/nix-env
real_readlink=$(command -v readlink)
mode=${1:-fetched}
case $mode in fetched | valid) ;; *) echo "fetch-gc: unknown mode $mode" >&2; exit 2 ;; esac
. "$cache_dir/test-support.sh"
TMPDIR=$(cd "${TMPDIR:-/tmp}" && pwd -P)
export TMPDIR
setup_test
trap 'chmod -R u+w "$t"; rm -rf "$t"' EXIT
mkdir -p "$t/tmp" "$t/cache" "$t/home" "$t/profiles"
export TMPDIR=$t/tmp XDG_CACHE_HOME=$t/cache HOME=$t/home
export TEST_SOURCE="local?root=$t/source" TEST_MAIN="local?root=$t/main"

# The system and its reference, built unsigned in a source store and signed into the bucket.
mkdir -p "$t/toplevel/bin"
printf '#!/bin/sh\necho "switch $1" >>"$TEST_ROOT/switched"\n' >"$t/toplevel/bin/switch-to-configuration"
chmod +x "$t/toplevel/bin/switch-to-configuration"
# The real store holds the same toplevel too, so the fetch can execute its switch by its path.
path=$("$CACHE_TEST_NIX" store add --name system "$t/toplevel")
export NIX_CONFIG=$'substituters =\nrequire-sigs = true'
echo dependency >"$t/dependency"
dependency=$("$CACHE_TEST_NIX" --store "$TEST_SOURCE" store add --mode text --name dependency \
	"$t/dependency")
mkdir -p "$t/source/nix/store"
cp -R "$t/toplevel" "$t/source$path"
printf '%s\n\n1\n%s\n' "$path" "$dependency" \
	| NIX_REMOTE=$TEST_SOURCE "$CACHE_TEST_NIX_STORE" --register-validity
"$CACHE_TEST_NIX" key generate-secret --key-name example.com-1 >"$t/nix-key"
"$CACHE_TEST_NIX" key convert-secret-to-public <"$t/nix-key" >"$t/nix-key.pub"
"$CACHE_TEST_NIX" store sign --store "$TEST_SOURCE" --key-file "$t/nix-key" -r "$path"
"$CACHE_TEST_NIX" copy --from "$TEST_SOURCE" --to "file://$t/bucket" "$path"
jq --arg key "$(cat "$t/nix-key.pub")" '.trusted = $key | del(.substituters)' "$t/fetch.json" >"$t/config"
mv "$t/config" "$t/fetch.json"
pointer a1 2026-10-26T13:00:00Z
echo /nix/store/2123456789abcdfghijklmnpqrsvwxyz-previous >"$t/current"
# An already valid system is in the main store unrooted and gone from the bucket, so no fetch can
# bring it back.
if [ "$mode" = valid ]; then
	"$CACHE_TEST_NIX" copy --no-check-sigs --from "$TEST_SOURCE" --to "$TEST_MAIN" "$path"
	hash=${path#/nix/store/}
	rm "$t/bucket/${hash%%-*}.narinfo"
fi

# The fetch's own commands on a real main store, collected right after each store command.
cat >"$t/bin/nix-store" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
status=0
NIX_REMOTE=$TEST_MAIN "$CACHE_TEST_NIX_STORE" "$@" || status=$?
echo "after $1" >>"$TEST_ROOT/main-gc"
"$CACHE_TEST_NIX" store gc --store "$TEST_MAIN" >>"$TEST_ROOT/main-gc" 2>&1
exit "$status"
SH
cat >"$t/bin/nix-env" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "$#" -gt 0 ]; do
	if [ "$1" = -p ]; then args+=(-p "$TEST_ROOT/profiles/system"); shift; else args+=("$1"); fi
	shift
done
NIX_REMOTE=$TEST_MAIN "$CACHE_TEST_NIX_ENV" "${args[@]}"
SH
chmod +x "$t/bin/nix-store" "$t/bin/nix-env"
held=false
"$CACHE_TEST_NIX" path-info --store "$TEST_MAIN" "$path" >/dev/null 2>&1 && held=true
if [ "$held" != "$([ "$mode" = valid ] && echo true || echo false)" ]; then
	echo "fetch-gc: the main store's holding the system before the fetch was $held" >&2
	exit 1
fi

status=0
fetch_test >"$t/log" 2>&1 || status=$?
if [ "$status" != 0 ]; then
	cat "$t/log" "$t/main-gc" 2>/dev/null
	echo "fetch-gc: the fetch failed with status $status" >&2
	exit 1
fi
grep -q '^after ' "$t/main-gc" || {
	echo 'fetch-gc: no collection ran after a store command' >&2; exit 1;
}
if [ "$mode" = valid ] && grep -q "from 'file://" "$t/log"; then
	echo 'fetch-gc: the already valid system was fetched again' >&2; exit 1
fi
"$CACHE_TEST_NIX" store gc --store "$TEST_MAIN" >>"$t/main-gc" 2>&1
"$CACHE_TEST_NIX" path-info --store "$TEST_MAIN" "$path" "$dependency" >/dev/null || {
	cat "$t/main-gc"; echo 'fetch-gc: collection removed the fetched system' >&2; exit 1;
}
[ "$("$real_readlink" "$t/profiles/$("$real_readlink" "$t/profiles/system")")" = "$path" ]
[ "$(cat "$t/switched")" = "switch switch" ]
[ "$(jq -r .path "$MACHINE_CACHE_APPLIED")" = "$path" ]
# The work directory's root ends with the fetch, which leaves the profile alone holding it.
for root in "$t/main/nix/var/nix/gcroots/auto/"*; do
	[ ! -L "$root" ] || [[ $("$real_readlink" "$root") != "$t/tmp/"* ]] || {
		echo 'fetch-gc: a root outlived the fetch' >&2; exit 1;
	}
done
if [ "$mode" = valid ]; then
	echo 'fetch-gc: an already valid system and its reference survive collection until the profile'
else
	echo 'fetch-gc: a fetched system and its reference survive collection right after the realize'
fi
