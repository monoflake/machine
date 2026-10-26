#!/usr/bin/env bash
# Own upgrades use newer answers first and retain cap enforcement after the object sweep.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")" && pwd)
. "$cache_dir/test-support.sh"
setup_test
trap 'rm -rf "$t"' EXIT
export CACHE_TEST_SCRIPTS=$cache_dir/.. MACHINE_CACHE_APPLIED=$t/state/cache-applied
cat >"$t/bin/fetch-command" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
. "$CACHE_TEST_SCRIPTS/protocol.sh"
. "$CACHE_TEST_SCRIPTS/fetch.sh"
SH
mkdir -p "$t/system/bin"
cat >"$t/system/bin/switch-to-configuration" <<'SH'
#!/usr/bin/env bash
echo switch >>"$TEST_ROOT/switched"
SH
chmod +x "$t/bin/fetch-command" "$t/system/bin/switch-to-configuration"
jq '.machine="a1" | .builders |= map(select(.name == "a2"))' "$t/fetch.json" >"$t/own-fetch.json"
jq --arg t "$t" '.self="cache" | .fetch={command:($t+"/bin/fetch-command"),config:($t+"/own-fetch.json")} | .machines.a1={flake:"https://example.com/machines",host:"a1",builders:{},slots:[],gap:20}' "$t/build.json" >"$t/self.json"
export MACHINE_CACHE_CONFIG=$t/self.json
pointer a2 2026-10-26T13:00:00Z a1
bash -euo pipefail "$t/run.sh" a1 --self
[ ! -f "$t/switched" ]
[ "$(jq -r .at "$MACHINE_CACHE_APPLIED")" = 2026-10-26T13:00:00Z ]
export TEST_OUTPUT=$t/system
bash -euo pipefail "$t/run.sh" a1 --self
[ -f "$t/switched" ]
[ "$(jq -r .path "$MACHINE_CACHE_APPLIED")" = "$t/system" ]
[ ! -f "$t/bucket/pending/a1/a1" ]
jq '.self="build" | .cap=80' "$t/self.json" >"$t/large.json"
export MACHINE_CACHE_CONFIG=$t/large.json
rm -f "$t/bucket/"*.narinfo "$t/bucket/nar/"* "$t/bucket/nix-cache-info"
if bash -euo pipefail "$t/run.sh" a1 --self >"$t/cap" 2>&1; then echo "own nonzero delta passed cap" >&2; exit 1; fi
grep -Eq 'delta [1-9][0-9]* more' "$t/cap"
printf '%02000d' 0 >"$t/bucket/stray.narinfo"
touch -d 2026-10-26T10:00:00Z "$t/bucket/stray.narinfo"
jq '.cap=1000' "$t/large.json" >"$t/ready.json"
export MACHINE_CACHE_CONFIG=$t/ready.json
bash -euo pipefail "$t/run.sh" a1 --self
[ ! -f "$t/bucket/stray.narinfo" ]
[ -f "$t/bucket/0123456789abcdfghijklmnpqrsvwxyz.narinfo" ]
[ ! -f "$t/bucket/pending/a1/a1" ]
export TEST_CACHE_HAS=true
: >"$t/uploaded"
bash -euo pipefail "$t/run.sh" a1 --self
[ ! -s "$t/uploaded" ]
echo "self: newer pointer first, equal pointer fallback, nonzero cap and swept upload passed"

jq '.machine="b1"' "$t/fetch.json" >"$t/refused-fetch.json"
jq --arg t "$t" '.builder="b1" | .fetch.config=($t+"/refused-fetch.json") | .machines.b1=.machines.a1 | del(.machines.a1)' \
	"$t/self.json" >"$t/refused-self.json"
export MACHINE_CACHE_CONFIG=$t/refused-self.json
pointer a1 2026-10-26T15:00:01Z b1
pointer a2 2026-10-26T13:00:00Z b1
printf '{malformed' >"$t/bucket/pending/b1/a2"
rm -f "$t/bucket/pending/b1/a2.sig"
ssh-keygen -q -Y sign -f "$t/a2" -n machine-cache "$t/bucket/pending/b1/a2"
cat >"$t/system/bin/switch-to-configuration" <<'SH'
#!/usr/bin/env bash
echo switch >>"$TEST_ROOT/switched"
echo "self build completed" >&2
SH
: >"$t/switched"
: >"$t/build-calls"
rm -f "$MACHINE_CACHE_APPLIED"
status=0
bash -euo pipefail "$t/run.sh" b1 --self >"$t/refused-log" 2>&1 || status=$?
[ "$status" = 1 ]
grep -q '^build ' "$t/build-calls"
[ "$(cat "$t/switched")" = "profile
switch" ]
[ "$(jq -r .path "$MACHINE_CACHE_APPLIED")" = "$t/system" ]
grep -q 'pointer pending/b1/a1 refused, more than one hour ahead' "$t/refused-log"
grep -q 'pointer pending/b1/a2 refused, malformed pointer' "$t/refused-log"
switched_line=$(grep -n '^self build completed$' "$t/refused-log" | cut -d: -f1)
while read -r refusal_line; do [ "$refusal_line" -gt "$switched_line" ]; done \
	< <(grep -n 'pointer pending/b1/.* refused' "$t/refused-log" | cut -d: -f1)
echo "self: future and malformed pointers allow a self build then fail with both reasons"

pointer a1 2026-10-26T13:00:00Z b1
cat >"$t/bin/nix-store" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_ROOT/nix-calls"
case $1 in
--check-validity) exit 1 ;;
--realise) echo "realise failed" >&2; exit 3 ;;
esac
SH
: >"$t/build-calls"
: >"$t/switched"
: >"$t/nix-calls"
rm -f "$MACHINE_CACHE_APPLIED"
status=0
bash -euo pipefail "$t/run.sh" b1 --self >"$t/realise-log" 2>&1 || status=$?
[ "$status" = 1 ]
grep -q -- "--realise $path" "$t/nix-calls"
grep -q '^realise failed$' "$t/realise-log"
! grep -q '^build ' "$t/build-calls"
[ ! -s "$t/switched" ]
[ ! -f "$MACHINE_CACHE_APPLIED" ]
echo "self: a newer valid pointer whose realise fails never starts a self build"
