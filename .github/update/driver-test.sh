#!/usr/bin/env bash
# The driver's package evaluated from this checkout's manifest.lock, then from a copy whose lock is
# the hand-written driver.lock, which nothing but this test reads.
set -o errexit -o nounset -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
rsync -a --exclude=.jj --exclude=.git --exclude=node_modules "$root/" "$t/"
cp "$here/driver.lock" "$t/system/containers/manifest.lock"
evaluated() { nix eval --impure --json --file "$here/driver-test.nix" --apply "f: f { $1 }"; }
evaluated "root = $root;"
echo
evaluated "root = $t; fixture = true;"
echo
echo "driver: the package evaluated from this checkout's lock and from the fixture's"
