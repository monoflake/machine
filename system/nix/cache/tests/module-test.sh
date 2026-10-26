#!/usr/bin/env bash
# Both builder upgrade modes retain their generated units on each Linux architecture.
set -o errexit -o nounset -o pipefail
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
rsync -a --exclude=.jj --exclude=.git --exclude=node_modules ../../../../ "$t/"
nix eval --impure --json --expr "
let flake = builtins.getFlake \"path:$t\";
in import $(pwd)/eval/module-test.nix { inherit flake; }
" >"$t/result"
jq -e 'all(.[]; .passed)' "$t/result" >/dev/null
for system in x86_64-linux aarch64-linux; do
	jq -r --arg s "$system" '.[$s].script' "$t/result" >"$t/run.sh"
	shellcheck "$t/run.sh"
done
echo "modules: both own upgrade modes and all slot timers passed for both Linux architectures"
