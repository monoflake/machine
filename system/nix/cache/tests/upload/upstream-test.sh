#!/usr/bin/env bash
# The run's own set asked of a binary cache by Nix from the locked input, a path it holds left out,
# one it lacks kept, and one not reached failing the run, docs/cache.md.
set -euo pipefail
cache_dir=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${MACHINE_CACHE_STORE_TOOLS:-}" ]; then
	inputs=$(realpath "$(mktemp -d)")
	trap 'rm -rf "$inputs"' EXIT
	cp "$cache_dir/../../../../"{flake.nix,flake.lock} "$inputs/"
	nix shell --inputs-from "path:$inputs" nixpkgs#nix nixpkgs#coreutils nixpkgs#jq \
		-c env MACHINE_CACHE_STORE_TOOLS=1 MACHINE_CACHE_TOOLS=1 ${TMPDIR:+TMPDIR="$TMPDIR"} \
		bash "$0" "$@"
	exit
fi
real_nix=$(command -v nix)
. "$cache_dir/test-support.sh"
TMPDIR=$(cd "${TMPDIR:-/tmp}" && pwd -P)
export TMPDIR
setup_test
trap 'chmod -R u+w "$t"; rm -rf "$t"' EXIT
rm "$t/bin/nix"
mkdir -p "$t/cache" "$t/home"
export XDG_CACHE_HOME=$t/cache HOME=$t/home
source="local?root=$t/source"
echo held >"$t/held"
echo lacked >"$t/lacked"
held=$("$real_nix" --store "$source" store add --mode text --name held "$t/held")
lacked=$("$real_nix" --store "$source" store add --mode text --name lacked "$t/lacked")
"$real_nix" copy --no-check-sigs --from "$source" --to "file://$t/fake-upstream" "$held"
. "$cache_dir/../protocol.sh"
. "$cache_dir/../run.sh"
work=$t/work
printf '%s\n' "$held" "$lacked" >"$work/closure"
upstream=file://$t/fake-upstream
own_set
[ "$(cat "$work/lacking")" = "$lacked" ]
echo "upstream: Nix leaves out the path the cache holds and keeps the one it lacks"

upstream=http://localhost:1
status=0
own_set 2>"$t/unreached" || status=$?
[ "$status" = 1 ]
grep -q "machine-cache: upstream http://localhost:1 could not be asked for the closure; nothing published" \
	"$t/unreached"
echo "upstream: a cache Nix cannot reach fails the run"
