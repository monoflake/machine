#!/usr/bin/env bash
# The cache's tests, each run in turn and the first failure stopping them, docs/cache.md.
set -o errexit -o nounset -o pipefail
cd "$(dirname "$0")"
for t in endpoint-test.sh sweep-test.sh build-test.sh; do
	bash "$t"
done
