#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
t=$(realpath "$(mktemp -d)")
trap 'rm -rf "$t"' EXIT
export TEST_ROOT=$t
mkdir "$t/bin"
cat >"$t/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_ROOT/calls"
case $1 in
start) exit "${START_STATUS:-0}" ;;
show)
	[ "$*" = "show -p Result --value ${EXPECTED_UNIT:?}" ]
	if [ "${START_STATUS:-0}" = 0 ]; then echo success; else echo exit-code; fi
	exit "${SHOW_STATUS:-0}"
	;;
*) exit 99 ;;
esac
SH
cat >"$t/bin/readlink" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = /run/current-system ]
echo readlink >>"$TEST_ROOT/calls"
echo /nix/store/0123456789abcdfghijklmnpqrsvwxyz-system
exit "${READLINK_STATUS:-0}"
SH
chmod +x "$t/bin/"*
export PATH=$t/bin:$PATH
run() {
	local expected=$1 status=0
	: >"$t/calls"
	bash -euo pipefail "$here/../nudge.sh" >"$t/output" 2>"$t/error" || status=$?
	[ "$status" = "$expected" ]
}
accepted() {
	export SSH_ORIGINAL_COMMAND=$1 EXPECTED_UNIT=update-now@$1.service START_STATUS=$2
	run "$2"
	if [ "$2" = 0 ]; then echo success; else echo exit-code; fi >"$t/expected"
	printf 'start %s\nshow -p Result --value %s\n' "$EXPECTED_UNIT" "$EXPECTED_UNIT" >"$t/expected-calls"
	if [ "$1" = system ]; then
		echo /nix/store/0123456789abcdfghijklmnpqrsvwxyz-system >>"$t/expected"
		echo readlink >>"$t/expected-calls"
	fi
	cmp "$t/output" "$t/expected"
	cmp "$t/calls" "$t/expected-calls"
	[ ! -s "$t/error" ]
}
accepted system 0
accepted driver 0
for command in '' 'system; reboot' 'system extra' ' system' restart 'system ' $'system\nreboot'; do
	export SSH_ORIGINAL_COMMAND=$command
	run 1
	[ ! -s "$t/calls" ]
	[ ! -s "$t/output" ]
	printf 'nudge: refused %q\n' "$command" >"$t/expected"
	cmp "$t/error" "$t/expected"
	[ "$(wc -l <"$t/error")" -eq 1 ]
done
unset SSH_ORIGINAL_COMMAND
run 1
printf "nudge: refused ''\n" >"$t/expected"
cmp "$t/error" "$t/expected"
[ ! -s "$t/calls" ]
[ ! -s "$t/output" ]
accepted system 7
accepted driver 8
export SHOW_STATUS=9 READLINK_STATUS=10
accepted system 0
accepted system 7
echo 'nudge shell: system, driver, exact commands, refusals, failed starts and preserved exit status passed'
