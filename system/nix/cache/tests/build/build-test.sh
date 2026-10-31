#!/usr/bin/env bash
# ../../build.nix's machine-cache-run as a builder's system holds it on each Linux system, git
# on its PATH, as Nix runs git to fetch a git+ssh flake.
set -o errexit -o nounset -o pipefail

# Nix reads a copy of the flake, as git's index lacks what jj adds, the workspace's docs/lessons.md.
t=$(realpath "$(mktemp -d)")
trap 'rm -rf "$t"' EXIT
rsync -a --exclude=.jj --exclude=.git --exclude=node_modules --exclude=target --exclude=/lib "$(dirname "$0")/../../../../../" "$t/"

paths=$(nix eval --impure --json --expr "
let
  flake = builtins.getFlake \"path:$t\";
  inherit (flake.inputs.nixpkgs) lib;
  builder = s: lib.nixosSystem {
    modules = [
      flake.nixosModules.machine
      $t/system/template/configuration.nix
      {
        nixpkgs.hostPlatform = s;
        machine.cache = {
          enable = true;
          bucket = \"/var/lib/machine-cache-bucket\";
          builder = {
            signingKey = \"/var/lib/secrets/nix-key\";
            pointerKey = \"/var/lib/secrets/pointer-key\";
            accessKey = \"/var/lib/secrets/access-key\";
          };
          builds.c1.flake = \"git+ssh://git@example.com/machines?dir=c1\";
        };
      }
    ];
  };
  run = s: lib.findFirst (p: p.name or \"\" == \"machine-cache-run\") null
    (builder s).config.environment.systemPackages;
  line = s: lib.findFirst (lib.hasPrefix \"export PATH=\") \"\" (lib.splitString \"\n\" (run s).text);
in
lib.genAttrs [ \"x86_64-linux\" \"aarch64-linux\" ] (s: lib.splitString \":\" (line s))
")

failed=0
for s in x86_64-linux aarch64-linux; do
	if ! jq -e --arg s "$s" '.[$s] | any(test("^(export PATH=\")?/nix/store/[0-9a-z]{32}-git(-minimal)?-[0-9][^/]*/bin$"))' \
		<<<"$paths" >/dev/null; then
		echo "machine-cache-run: no git on its PATH for $s, $(jq -c --arg s "$s" '.[$s]' <<<"$paths")" >&2
		failed=1
	fi
done
[ "$failed" = 0 ] && echo "machine-cache-run: git on its PATH for x86_64-linux and aarch64-linux"
exit "$failed"
