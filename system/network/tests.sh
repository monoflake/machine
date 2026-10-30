#!/usr/bin/env bash
# Network options and the closer run without reaching another machine.
set -o errexit -o nounset -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
if [ -z "${MACHINE_NETWORK_TOOLS:-}" ]; then
	t=$(realpath "$(mktemp -d)")
	trap 'rm -rf "$t"' EXIT
	cp "$here/../../flake.nix" "$here/../../flake.lock" "$t/"
	nix shell --inputs-from "path:$t" nixpkgs#jq nixpkgs#gawk \
		-c env MACHINE_NETWORK_TOOLS=1 ${TMPDIR:+TMPDIR="$TMPDIR"} bash "$0"
	exit
fi
tmp=$(realpath "$(mktemp -d)")
trap 'rm -rf "$tmp"' EXIT
nix eval --impure --json --file "$here/eval-test.nix" --apply 'f: f {}' >"$tmp/evaluated"
jq -r .rules "$tmp/evaluated" >"$tmp/input.nft"
jq -r .script "$tmp/evaluated" >"$tmp/close.sh"
bash "$here/ssh/rules-test.sh" "$tmp/input.nft"
bash "$here/ssh/state-test.sh" "$tmp/input.nft" "$tmp/close.sh"
echo "network: $(jq '.tests | length' "$tmp/evaluated") evaluation checks passed"
bash "$here/addresses/tests.sh"
