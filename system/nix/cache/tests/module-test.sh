#!/usr/bin/env bash
# Both builder upgrade modes retain their generated units on each Linux architecture.
set -o errexit -o nounset -o pipefail
t=$(realpath "$(mktemp -d)")
trap 'rm -rf "$t"' EXIT
rsync -a --exclude=.jj --exclude=.git --exclude=node_modules --exclude=target ../../../../ "$t/"
nix eval --impure --json --expr "
let flake = builtins.getFlake \"path:$t\";
in import $(pwd)/eval/module-test.nix { inherit flake; }
" >"$t/result"
jq -e 'all(.[]; .passed)' "$t/result" >/dev/null
for system in x86_64-linux aarch64-linux; do
	jq -r --arg s "$system" '.[$s].script' "$t/result" >"$t/run.sh"
	shellcheck "$t/run.sh"
done
jq -r '."x86_64-linux".storage' "$t/result" >"$t/prepare"
shellcheck -s bash "$t/prepare"
mkdir "$t/bin"
export PREPARE_TEST=$t
cat >"$t/bin/btrfs" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$PREPARE_TEST/btrfs-calls"
case "$1 $2" in
'subvolume show') [ -f "$3/.subvolume" ] ;;
'subvolume create') mkdir "$3"; touch "$3/.subvolume" ;;
'qgroup limit') [ "$3" = 10000000000 ]; [ -f "$4/.subvolume" ] ;;
*) exit 1 ;;
esac
SH
chmod +x "$t/bin/btrfs"
mkdir "$t/data"
sed "s,/data,$t/data,g" "$t/prepare" >"$t/local-prepare"
PATH="$t/bin:$PATH" bash -euo pipefail "$t/local-prepare"
echo kept >"$t/data/build/root/kept"
PATH="$t/bin:$PATH" bash -euo pipefail "$t/local-prepare"
[ "$(cat "$t/data/build/root/kept")" = kept ]
[ "$(grep -c '^subvolume create ' "$t/btrfs-calls")" = 1 ]
[ "$(grep -c '^qgroup limit 10000000000 ' "$t/btrfs-calls")" = 2 ]
for directory in root builds log tmp cache daemon-tmp; do [ -d "$t/data/build/$directory" ]; done
echo "build-store: preparation creates once, reapplies the quota and preserves existing data"
mkdir -p "$t/ordinary/data/build"
echo kept >"$t/ordinary/data/build/kept"
sed "s,/data,$t/ordinary/data,g" "$t/prepare" >"$t/ordinary-prepare"
if PATH="$t/bin:$PATH" bash -euo pipefail "$t/ordinary-prepare" >"$t/refused" 2>&1; then
	echo "build-store: an ordinary directory bypassed subvolume creation" >&2; exit 1
fi
[ "$(cat "$t/ordinary/data/build/kept")" = kept ]
grep -q 'docs/cache.md#existing-directory-migration' "$t/refused"
echo "build-store: preparation refuses an ordinary directory without replacing its data"
echo "modules: both own upgrade modes and all slot timers passed for both Linux architectures"
