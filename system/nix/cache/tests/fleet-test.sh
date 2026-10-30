#!/usr/bin/env bash
# Inventory refusals and daily orders agree with the shell protocol.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")" && pwd)
. "$cache_dir/test-support.sh"
. "$cache_dir/../protocol.sh"
t=$(realpath "$(mktemp -d)")
trap 'rm -rf "$t"' EXIT
cp "$cache_dir/../../../../"{flake.nix,flake.lock} "$t/"
nix eval --impure --json --expr "
let lib = (builtins.getFlake \"path:$t\").inputs.nixpkgs.lib;
in import $cache_dir/eval/fleet-test.nix { inherit lib; }
" >"$t/result"
while read -r entry; do
	order=$(cache_order "$(jq -r .name <<<"$entry")" "$(jq -r .date <<<"$entry")" "$(jq -c .builders <<<"$entry")")
	jq -e --arg order "$order" '.order == ($order | split("\n"))' <<<"$entry" >/dev/null
done < <(jq -c '.orders[]' "$t/result")
echo "fleet: $(jq -r .passed "$t/result") assertions and 16 Nix versus shell orders passed"
