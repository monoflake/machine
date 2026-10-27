#!/usr/bin/env bash
# Self builds honor an explicit store and set the profile from the data store before activation.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")/.." && pwd)
. "$cache_dir/test-support.sh"
mode=${1:-configured}
setup_test
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/system/bin" "$t/tmp"
export TMPDIR=$t/tmp
cat >"$t/system/bin/switch-to-configuration" <<'SH'
#!/usr/bin/env bash
echo switch >>"$TEST_ROOT/self-events"
SH
cat >"$t/bin/nix-env" <<'SH'
#!/usr/bin/env bash
echo profile >>"$TEST_ROOT/self-events"
printf '%s\n' "$*" >>"$TEST_ROOT/profile-calls"
SH
mv "$t/bin/nix" "$t/bin/fake-nix"
cat >"$t/bin/nix" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_ROOT/store-calls"
if [[ $* == 'store gc '* ]]; then
	echo gc >>"$TEST_ROOT/self-events"
	exit 0
fi
if [ "$1" = copy ]; then
	if [[ $* == *'--to local '* ]]; then
		echo 'self-copy: a copy into the main store leaves the system unrooted' >&2; exit 81
	fi
	echo upload >>"$TEST_ROOT/self-events"
fi
exec "$TEST_ROOT/bin/fake-nix" "$@"
SH
chmod +x "$t/system/bin/switch-to-configuration" "$t/bin/"*
if [ "$mode" = configured ]; then
	store="local?build-dir=$t/builds&log=$t/log"
	data=false
else
	store="local?root=$t/root"
	data=true
fi
jq --arg store "$store" --argjson data "$data" \
	'.store=$store | .data=$data | .self="build" | .machines.a1=.machines.c1' \
	"$t/build.json" >"$t/self.json"
export TEST_OUTPUT=$t/system
if [ "$mode" = configured ]; then
	MACHINE_CACHE_CONFIG=$t/self.json bash -euo pipefail "$t/run.sh" c1 --now >"$t/log" 2>&1
	for command in eval build; do
		grep -q "^$command .*--store $store " "$t/store-calls" || {
			echo "self-store: consumer $command dropped the explicit store" >&2; exit 1;
		}
	done
	: >"$t/store-calls"
fi
MACHINE_CACHE_CONFIG=$t/self.json bash -euo pipefail "$t/run.sh" a1 --self >"$t/log" 2>&1 || {
	cat "$t/log" >&2; exit 1;
}
if [ "$mode" = configured ]; then
	grep -q "^build .*--store $store " "$t/store-calls" || {
		echo 'self-store: data=false self build dropped the explicit store' >&2; exit 1;
	}
	grep -qxF -- "-p /nix/var/nix/profiles/system --set $t/system" "$t/profile-calls" || {
		echo 'self-store: data=false changed the profile command' >&2; exit 1;
	}
else
	[ "$(cat "$t/self-events")" = "profile
switch
upload
gc" ] || {
		cat "$t/self-events" >&2
		echo 'self-copy: profile from the chroot store missing before switch' >&2; exit 1;
	}
	grep -qxF -- "--option substituters $store&trusted=true -p /nix/var/nix/profiles/system --set $t/system" \
		"$t/profile-calls" || {
		cat "$t/profile-calls" >&2
		echo 'self-copy: the profile command does not substitute from the trusted chroot store alone' >&2; exit 1;
	}
	grep -q "^build .*--store $store --eval-store $store " "$t/store-calls"
fi
grep -q "^path-info -r --store $store " "$t/store-calls"
grep -q "^copy --from $store --to file://" "$t/store-calls"
if [ "$mode" = configured ]; then
	echo 'self-store: data=false preserves the explicit store for consumer and self builds and uploads'
else
	echo 'self-copy: chroot build and evaluation, profile substituted from the chroot store before switch, chroot upload then GC'
fi
