#!/usr/bin/env bash
# Every run ends with one outcome after cleanup, including failures through errexit.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")" && pwd)
. "$cache_dir/test-support.sh"

check_run() {
	local want=$1 expected_status=$2 status=0
	shift 2
	bash -euo pipefail "$t/run.sh" "$machine" "$@" >"$t/stdout" 2>"$t/stderr" || status=$?
	check_outcome "$want" "$expected_status" "$status"
}
check_outcome() {
	local want=$1 expected_status=$2 status=$3
	[ "$status" = "$expected_status" ] || {
		cat "$t/stdout" "$t/stderr" >&2
		echo "$case_name returned $status instead of $expected_status" >&2
		exit 1
	}
	if [ "$(grep -c '^machine-cache outcome=' "$t/stdout")" != 1 ]; then
		fail "$case_name outcome line count is not one"
	fi
	if [ "$(tail -n 1 "$t/stdout")" != "machine-cache outcome=$want consumer=$machine$own" ]; then
		fail "$case_name final outcome line does not match"
	fi
	if [ -f "$t/lock.owner" ]; then fail "$case_name lock owner was not removed"; fi
	if compgen -G "$t/machine-cache.*" >/dev/null; then
		fail "$case_name work directory was not removed"
	fi
}
fail_command() {
	local command=$1 pattern=${2:-'*'}
	mv "$t/bin/$command" "$t/bin/$command-original"
	cat >"$t/bin/$command" <<SHIM
#!/usr/bin/env bash
case \$* in
$pattern) echo 'injected failure' >&2; exit 7 ;;
esac
exec "$t/bin/$command-original" "\$@"
SHIM
	chmod +x "$t/bin/$command"
}
run_case() (
	case_name=$1
	setup_test
	trap 'rm -rf "$t"' EXIT
	cat "$cache_dir/../endpoint.sh" "$t/run.sh" >"$t/with-endpoint"
	mv "$t/with-endpoint" "$t/run.sh"
	export MACHINE_CACHE_CONFIG=$t/build.json
	machine=c1; own=""
	case $case_name in
	built) echo "$ref" >"$t/hosts/c1/current"; check_run built 0 --now ;;
	confirmed) check_run confirmed 0 --now ;;
	legacy-built|legacy-confirmed)
		rmdir "$t/bucket/pending/c1"
		jq '.machines.c1.builders={}' "$t/build.json" >"$t/config"
		export MACHINE_CACHE_CONFIG=$t/config
		if [ "$case_name" = legacy-built ]; then
			echo "$ref" >"$t/hosts/c1/current"; check_run built 0 --now
		else check_run confirmed 0 --now
		fi ;;
	answered) pointer a2 2026-10-26T14:00:00Z; check_run answered 0 ;;
	manual-answered) pointer a2 2026-10-26T14:00:00Z; check_run answered 0 --now ;;
	claimed|last-claimed)
		echo 2026-10-26T14:00:00Z >"$t/bucket/pending/c1/a2.claim"
		if [ "$case_name" = last-claimed ]; then
			jq '.builder="a2"' "$t/build.json" >"$t/config"
			export MACHINE_CACHE_CONFIG=$t/config
			clock_at 2026-10-26T14:20:00Z
			echo 2026-10-26T14:19:30Z >"$t/bucket/pending/c1/a1.claim"
			check_run claimed 1
		else check_run claimed 0
		fi ;;
	skipped) clock_at 2026-10-26T14:20:00Z; check_run skipped 0 ;;
	late) clock_at 2026-10-26T14:45:00Z; check_run missed 1 ;;
	trigger-late)
		export TRIGGER_TIMER_REALTIME_USEC=$(($(cat "$t/clock") * 1000000))
		clock_at 2026-10-26T14:20:01Z; check_run missed 1 ;;
	lock|lock-expired)
		cat >"$t/bin/flock" <<'LOCK'
#!/usr/bin/env bash
if [ "$TEST_LOCK_EXPIRES" = true ]; then
	echo $(($(cat "$TEST_ROOT/clock") + 60)) >"$TEST_ROOT/clock"
else exit 1
fi
LOCK
		chmod +x "$t/bin/flock"
		export TEST_LOCK_EXPIRES=false
		[ "$case_name" != lock-expired ] || export TEST_LOCK_EXPIRES=true
		check_run missed 1 ;;
	state-directory)
		export MACHINE_CACHE_STATE=$t/current/invalid
		check_run failed 1 --now ;;
	lock-open)
		export MACHINE_CACHE_LOCK=$t/missing/lock
		check_run failed 1 --now ;;
	work-directory)
		export TMPDIR=$t/missing
		check_run failed 1 --now ;;
	missing-config)
		unset MACHINE_CACHE_CONFIG
		check_run failed 1 --now ;;
	unknown) machine=c2; check_run failed 1 ;;
	invalid-config) echo '{' >"$t/build.json"; check_run failed 5 ;;
	unlisted-builder)
		jq '.builder="a3"' "$t/build.json" >"$t/config"
		export MACHINE_CACHE_CONFIG=$t/config; check_run failed 1 ;;
	layout)
		rmdir "$t/bucket/pending/c1"; echo legacy >"$t/bucket/pending/c1"
		check_run failed 1 --now ;;
	endpoint)
		jq '.bucket="caches"' "$t/build.json" >"$t/config"
		export MACHINE_CACHE_CONFIG=$t/config MACHINE_CACHE_ENDPOINT=http://example.com
		check_run failed 1 --now ;;
	current) rm "$t/hosts/c1/current"; check_run failed 1 --now ;;
	upstream)
		echo "$ref" >"$t/hosts/c1/current"
		export TEST_UPSTREAM=down; check_run failed 1 --now ;;
	cap)
		echo "$ref" >"$t/hosts/c1/current"
		echo stray >"$t/bucket/stray"
		jq '.cap=0' "$t/build.json" >"$t/config"
		export MACHINE_CACHE_CONFIG=$t/config; check_run failed 1 --now ;;
	eval|build|closure|copy|claim|upload|signature|pointer)
		echo "$ref" >"$t/hosts/c1/current"
		case $case_name in
		eval) fail_command nix 'eval*' ;;
		build) fail_command nix 'build*' ;;
		closure) fail_command nix 'path-info*' ;;
		copy) fail_command nix 'copy*' ;;
		claim) fail_command rclone 'copyto*.claim' ;;
		upload) fail_command rclone 'copy\ *' ;;
		signature) fail_command rclone 'copyto*.sig' ;;
		pointer) fail_command rclone 'copyto*/pending/c1/a1' ;;
		esac
		check_run failed 7 --now ;;
	cleanup-term|cleanup-lock-error|cleanup-work-error)
		echo "$ref" >"$t/hosts/c1/current"
		export TEST_RM TEST_CLEANUP_CASE=$case_name
		TEST_RM=$(command -v rm)
		cat >"$t/bin/rm" <<'SHIM'
#!/usr/bin/env bash
"$TEST_RM" "$@" || exit $?
case $TEST_CLEANUP_CASE in
cleanup-term)
	if [ "$*" = "-f $TEST_ROOT/lock.owner" ]; then
		kill -TERM "$PPID"
		echo signalled >"$TEST_ROOT/cleanup-tested"
	fi ;;
cleanup-lock-error|cleanup-work-error)
	if { [ "$TEST_CLEANUP_CASE" = cleanup-lock-error ] && [ "$*" = "-f $TEST_ROOT/lock.owner" ]; } \
		|| { [ "$TEST_CLEANUP_CASE" = cleanup-work-error ] && [[ $* == "-rf $TEST_ROOT"/machine-cache.* ]]; }; then
		echo failed >"$TEST_ROOT/cleanup-tested"
		exit 7
	fi ;;
esac
SHIM
		chmod +x "$t/bin/rm"
		if [ "$case_name" = cleanup-term ]; then check_run built 0 --now
		else check_run built 7 --now
		fi
		if [ ! -s "$t/cleanup-tested" ]; then fail "$case_name cleanup was not tested"; fi ;;
	terminated)
		echo "$ref" >"$t/hosts/c1/current"
		mv "$t/bin/nix" "$t/bin/nix-original"
		cat >"$t/bin/nix" <<SHIM
#!/usr/bin/env bash
[ "\$1" != build ] || { echo \$\$ >"$t/building"; exec sleep 30; }
exec "$t/bin/nix-original" "\$@"
SHIM
		chmod +x "$t/bin/nix"
		bash -euo pipefail "$t/run.sh" c1 --now >"$t/stdout" 2>"$t/stderr" &
		run=$!
		for _ in {1..500}; do [ ! -s "$t/building" ] || break; sleep 0.01; done
		kill -TERM "$run" "$(cat "$t/building")"
		status=0
		wait "$run" || status=$?
		check_outcome failed 143 "$status" ;;
	no-machine)
		machine=""; status=0
		bash -euo pipefail "$t/run.sh" >"$t/stdout" 2>"$t/stderr" || status=$?
		check_outcome failed 1 "$status" ;;
	self-*)
		machine=a1; own=' self=failed'
		mkdir -p "$t/system/bin"
		printf '#!/usr/bin/env bash\necho switched\n' >"$t/system/bin/switch-to-configuration"
		chmod +x "$t/system/bin/switch-to-configuration"
		jq --arg t "$t" '.self="cache" |
			.fetch={command:($t+"/bin/fetch-command"),config:"unused"} |
			.machines.a1=.machines.c1' \
			"$t/build.json" >"$t/config"
		export MACHINE_CACHE_CONFIG=$t/config TEST_OUTPUT=$t/system
		cat >"$t/bin/fetch-command" <<'FETCH'
#!/usr/bin/env bash
echo fetching
exit "${TEST_FETCH_STATUS:-2}"
FETCH
		chmod +x "$t/bin/fetch-command"
		case $case_name in
		self-fetched) export TEST_FETCH_STATUS=0; own=' self=fetched'; check_run answered 0 --self ;;
		self-built) own=' self=built'; check_run built 0 --self ;;
		self-fetch-refused) export TEST_FETCH_STATUS=3; own=' self=built'; check_run failed 1 --self ;;
		self-fetch-error) export TEST_FETCH_STATUS=7; check_run failed 7 --self ;;
		self-build-error) fail_command nix 'build*'; check_run failed 7 --self ;;
		self-switch-error)
			echo 'exit 7' >>"$t/system/bin/switch-to-configuration"
			check_run failed 7 --self ;;
		self-record-error)
			mkdir "$t/state/cache-applied.new"
			own=' self=built'; check_run failed 1 --self
			if ! grep -qx switched "$t/stdout"; then fail "$case_name switch did not run"; fi
			if [ -f "$t/state/cache-applied" ]; then fail "$case_name applied state was recorded"; fi ;;
		esac ;;
	esac
	echo "outcome passed $case_name"
)
for case_name in built confirmed legacy-built legacy-confirmed answered manual-answered claimed \
	last-claimed skipped late trigger-late lock lock-expired state-directory lock-open \
	work-directory missing-config unknown invalid-config unlisted-builder \
	layout endpoint current upstream cap eval build closure copy claim upload signature \
	pointer cleanup-term cleanup-lock-error cleanup-work-error terminated no-machine self-fetched \
	self-built self-fetch-refused self-fetch-error self-build-error self-switch-error self-record-error; do
	run_case "$case_name"
done
