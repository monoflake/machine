#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
t=$(realpath "$(mktemp -d)")
trap 'rm -rf "$t"' EXIT
rsync -a --exclude=.jj --exclude=.git --exclude=node_modules --exclude=target --exclude=/lib "$here/../../../../" "$t/"
ssh-keygen -q -t ed25519 -N '' -C '' -f "$t/key"
openssl rand -base64 32 >"$t/nix-key"
nix eval --impure --json --expr "
let flake = builtins.getFlake \"path:$t\";
in import $here/driver-eval-test.nix {
  inherit flake;
  pointerKey = builtins.replaceStrings [ \"\\n\" ] [ \"\" ] (builtins.readFile $t/key.pub);
  nixKey = \"fixture:\" + builtins.replaceStrings [ \"\\n\" ] [ \"\" ] (builtins.readFile $t/nix-key);
}
" >"$t/result"
jq -e 'all(.[]; .passed)' "$t/result" >/dev/null
echo 'driver eval: exclusive sources, update requirement, binary paths, updater binary, isolated rollback PATH, hardening, timer, build guard configuration and whole system passed on both Linux architectures'
