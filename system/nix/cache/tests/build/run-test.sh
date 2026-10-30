#!/usr/bin/env bash
# Runs exercise cleanup with Nix from the locked input and a real disposable chroot store.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${MACHINE_CACHE_STORE_TOOLS:-}" ]; then
	inputs=$(realpath "$(mktemp -d)")
	trap 'rm -rf "$inputs"' EXIT
	cp "$cache_dir/../../../../"{flake.nix,flake.lock} "$inputs/"
	nix shell --inputs-from "path:$inputs" nixpkgs#nix nixpkgs#coreutils nixpkgs#jq nixpkgs#util-linux \
		-c env MACHINE_CACHE_STORE_TOOLS=1 MACHINE_CACHE_TOOLS=1 bash "$0" "$@"
	exit
fi
export CACHE_TEST_NIX
CACHE_TEST_NIX=$(command -v nix)
export CACHE_TEST_NIX_ENV=${CACHE_TEST_NIX%/*}/nix-env
real_readlink=$(command -v readlink)
. "$cache_dir/test-support.sh"
mode=${1:-success}
TMPDIR=$(cd "${TMPDIR:-/tmp}" && pwd -P)
export TMPDIR
setup_test
trap 'chmod -R u+w "$t"; rm -rf "$t"' EXIT
mkdir -p "$t/tmp" "$t/cache" "$t/state/cache-systems"
export TMPDIR=$t/tmp XDG_CACHE_HOME=$t/cache
export TEST_STORE="local?root=$t/root" TEST_MAIN="local?root=$t/main"
echo previous >"$t/previous"
previous=$("$CACHE_TEST_NIX" --store "$TEST_STORE" store add --mode text --name system "$t/previous")
export TEST_KEPT=$previous TEST_MODE=success TEST_OUTPUT=$previous
printf '%s\n' "$previous" >"$t/current"
printf '%s\n' "$previous" >"$t/hosts/c1/current"
jq --arg store "$TEST_STORE" '.data=true | .store=$store' "$t/build.json" >"$t/config"
mv "$t/config" "$t/build.json"
mv "$t/bin/nix" "$t/bin/fake-nix"
cat >"$t/bin/nix" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
build_root() {
	local link=(--no-link)
	while [ "$#" -gt 0 ]; do
		if [ "$1" = --out-link ]; then link=(--out-link "$2"); shift; fi
		shift
	done
	"$CACHE_TEST_NIX" build --store "$TEST_STORE" "${link[@]}" "$TEST_KEPT"
	printf '%s\n' "${link[1]-}" >"$TEST_ROOT/out-link"
}
if [[ $* == 'store gc '* ]]; then
	flock -n "$TEST_ROOT/lock" true && exit 71
	[ "$TEST_MODE" != gc-error ] || exit 72
	exec "$CACHE_TEST_NIX" "$@"
fi
# A copy into the main store reaches the test's main store instead.
if [ "$TEST_MODE" = self-gc ] && [[ $1 == copy && $* == *'--to local '* ]]; then
	args=("$@")
	for i in "${!args[@]}"; do [ "${args[i]}" != local ] || args[i]=$TEST_MAIN; done
	exec "$CACHE_TEST_NIX" "${args[@]}"
fi
if [[ $1 == build || $1 == eval ]]; then
	flock -n "$TEST_ROOT/lock" true && exit 73
	if [[ $* != *"--eval-store $TEST_STORE"* ]]; then
		echo 'build-store: evaluation is not in the chroot store' >>"$TEST_ROOT/flag-errors"
	fi
	[[ $* == *"--store $TEST_STORE"* ]] || echo 'build-store: build is not in the chroot store' >>"$TEST_ROOT/flag-errors"
	if [ "$1" = build ]; then
		mkdir -p "$TMPDIR/staging/nested"; touch "$TMPDIR/.hidden" "$TMPDIR/staging/nested/object"
		case $TEST_MODE in
		failure) exit 77 ;;
		term) kill -TERM "$PPID"; exit 78 ;;
		self) exit 79 ;;
		esac
		build_root "$@"
	fi
fi
exec "$TEST_ROOT/bin/fake-nix" "$@"
MOCK
chmod +x "$t/bin/nix"
assert_root() {
	local root
	root=$t/state/cache-systems/${2:-c1}
	if [ ! -L "$root" ] \
		|| [ "$("$real_readlink" "$root")" != "$1" ] || [ ! -e "$t/root$1" ]; then
		echo 'build-store: new system is not rooted by the expected run out-link' >&2
		exit 1
	fi
}
run_test --now >"$t/log" 2>&1 || { cat "$t/log"; exit 1; }
assert_root "$previous"
clock_at 2026-10-27T14:00:00Z
echo kept >"$t/kept"; echo discard >"$t/discard"
kept=$("$CACHE_TEST_NIX" --store "$TEST_STORE" store add --mode text --name system "$t/kept")
unrooted=$("$CACHE_TEST_NIX" --store "$TEST_STORE" store add --mode text --name intermediate "$t/discard")
if [ "$mode" = self-gc ]; then
	# The real store holds the same toplevel too, so the run can execute its switch by its path.
	mkdir -p "$t/toplevel/bin" "$t/profiles"
	printf '#!/bin/sh\necho switch >>"$TEST_ROOT/self-switched"\n' >"$t/toplevel/bin/switch-to-configuration"
	chmod +x "$t/toplevel/bin/switch-to-configuration"
	kept=$("$CACHE_TEST_NIX" store add --name system "$t/toplevel")
	dependency=$("$CACHE_TEST_NIX" --store "$TEST_STORE" store add --mode text --name dependency "$t/kept")
	cp -R "$t/toplevel" "$t/root$kept"
	printf '%s\n\n1\n%s\n' "$kept" "$dependency" \
		| NIX_REMOTE=$TEST_STORE "${CACHE_TEST_NIX%/*}/nix-store" --register-validity
	# A real main store collected right before and right after the profile command.
	cat >"$t/bin/nix-env" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "$#" -gt 0 ]; do
	if [ "$1" = -p ]; then args+=(-p "$TEST_ROOT/profiles/system"); shift; else args+=("$1"); fi
	shift
done
"$CACHE_TEST_NIX" store gc --store "$TEST_MAIN" >>"$TEST_ROOT/main-gc" 2>&1
HOME=$TEST_ROOT/home NIX_REMOTE=$TEST_MAIN NIX_CONFIG=$'substituters =\nrequire-sigs = true' \
	"$CACHE_TEST_NIX_ENV" "${args[@]}"
"$CACHE_TEST_NIX" store gc --store "$TEST_MAIN" >>"$TEST_ROOT/main-gc" 2>&1
SH
fi
if [ "$mode" = self-copy-failure ]; then
	cat >"$t/bin/nix-env" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$TEST_ROOT/failed-copy"
exit 80
SH
fi
export TEST_KEPT=$kept TEST_MODE=$mode TEST_OUTPUT=$kept
printf '%s\n' "$kept" >"$t/current"
printf '%s\n' "$kept" >"$t/hosts/c1/current"
status=0
if [[ $mode == self* ]]; then
	jq '.self="build" | .machines.a1=.machines.c1' "$t/build.json" >"$t/self.json"
	MACHINE_CACHE_CONFIG=$t/self.json bash -euo pipefail "$t/run.sh" a1 --self >"$t/log" 2>&1 || status=$?
else run_test --now >"$t/log" 2>&1 || status=$?
fi
case $mode in
success|self-gc) [ "$status" = 0 ] || { cat "$t/log" "$t/main-gc" 2>/dev/null; exit 1; } ;;
failure|term|self|self-copy-failure) [ "$status" != 0 ] ;;
gc-error)
	[ "$status" != 0 ] || { echo 'build-store: collector failure was ignored' >&2; exit 1; } ;;
esac
case $mode in
success|gc-error) assert_root "$kept" ;;
failure|term|self)
	assert_root "$previous"
	[ ! -e "$t/root$kept" ] || { echo 'build-store: failed build left its unrooted system' >&2; exit 1; } ;;
self-copy-failure)
	assert_root "$previous"
	assert_root "$kept" a1
	grep -qxF -- "--option substituters $TEST_STORE&trusted=true -p /nix/var/nix/profiles/system --set $kept" \
		"$t/failed-copy" 2>/dev/null || {
		echo 'build-store: self copy failure was not exercised' >&2; exit 1;
	} ;;
self-gc)
	assert_root "$kept" a1
	"$CACHE_TEST_NIX" store gc --store "$TEST_MAIN" >>"$t/main-gc" 2>&1
	"$CACHE_TEST_NIX" path-info --store "$TEST_MAIN" "$kept" "$dependency" >/dev/null || {
		cat "$t/main-gc"; echo 'build-store: collection removed the self system from the main store' >&2; exit 1;
	}
	[ "$("$real_readlink" "$t/profiles/$("$real_readlink" "$t/profiles/system")")" = "$kept" ]
	[ -f "$t/self-switched" ] ;;
esac
if [[ $mode == self || $mode == self-copy-failure ]]; then
	[ ! -f "$t/switched" ] || { echo 'build-store: failed self build or copy switched the system' >&2; exit 1; }
fi
if [ "$mode" = gc-error ]; then
	grep -q 'outcome=confirmed' "$t/log" || {
		cat "$t/log"; echo 'build-store: GC failure did not preserve the outcome' >&2; exit 1;
	}
	[ -e "$t/root$unrooted" ]
else
	[ ! -e "$t/root$unrooted" ] || { cat "$t/log"; echo 'build-store: unrooted intermediate was not collected' >&2; exit 1; }
fi
[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
[ -d "$t/root/nix/store" ]
[ ! -f "$t/flag-errors" ] || { cat "$t/flag-errors" >&2; exit 1; }
flock -n "$t/lock" true
if [ "$mode" = gc-error ]; then
	echo 'build-store: GC failure fails the run, preserves its outcome and releases the lock'
elif [ "$mode" = self-gc ]; then
	echo 'build-store: the self system and its reference survive main store collection around the profile'
else
	printf 'build-store: %s keeps the rooted system, reclaims intermediates and tmp, holds the lock\n' "$mode"
fi
