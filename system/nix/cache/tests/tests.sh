#!/usr/bin/env bash
# The cache's tests, each run in turn and the first failure stopping them, docs/cache.md.
set -o errexit -o nounset -o pipefail
cd "$(dirname "$0")"
for t in endpoint-test.sh sweep-test.sh protocol-test.sh delivery-test.sh lock-test.sh outcome-test.sh fleet-test.sh module-test.sh compatibility-test.sh self-test.sh self-marker/sweep-test.sh self-marker/run-test.sh self-marker/delete-test.sh self-marker/readers-test.sh build-test.sh; do
	bash "$t"
done
