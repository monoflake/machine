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
in import $here/nudge-eval-test.nix {
  inherit flake;
  nixKey = \"fixture:\" + builtins.replaceStrings [ \"\\n\" ] [ \"\" ] (builtins.readFile $t/nix-key);
  key = builtins.replaceStrings [ \"\\n\" ] [ \"\" ] (builtins.readFile $t/key.pub);
}
" >"$t/result"
jq -e 'all(.[]; .passed)' "$t/result" >/dev/null
node --input-type=commonjs - "$t/result" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
for (const { rule } of Object.values(JSON.parse(fs.readFileSync(process.argv[2], 'utf8')))) {
	let authorize;
	vm.runInNewContext(rule, {
		polkit: { addRule: fn => { authorize = fn; }, Result: { YES: 'yes' } },
	});
	for (const user of ['nudge', 'root', 'other']) {
		for (const id of ['org.freedesktop.systemd1.manage-units', 'org.freedesktop.systemd1.manage-unit-files']) {
			for (const verb of ['start', 'stop', 'restart', 'reload', 'enable', undefined]) {
				for (const unit of ['update-now@system.service', 'update-now@driver.service', 'update-now@other.service', 'sshd.service', undefined]) {
					const expected = user === 'nudge' && id === 'org.freedesktop.systemd1.manage-units' &&
						verb === 'start' && ['update-now@system.service', 'update-now@driver.service'].includes(unit);
					assert.equal(authorize({ id, lookup: name => ({ verb, unit })[name] }, { user }),
						expected ? 'yes' : undefined);
				}
			}
		}
	}
}
JS
echo 'nudge eval: pairing, account, exact key, package forced command and shell, isolated PATH, polkit permissions, unchanged SSH and firewall, and disabled defaults passed on both Linux architectures'
