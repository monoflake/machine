#!/usr/bin/env bash
# The cache's tests, each run in turn and the first failure stopping them, docs/cache.md.
set -o errexit -o nounset -o pipefail
cd "$(dirname "$0")"
for t in endpoint-test.sh fetch/protocol-test.sh delivery-test.sh lock-test.sh outcome-test.sh fleet-test.sh module-test.sh compatibility-test.sh self-test.sh upload/run-test.sh upload/upstream-test.sh build/build-test.sh fetch/gc-test.sh; do
	bash "$t"
done
for mode in success failure term self self-copy-failure self-gc gc-error; do
	bash build/run-test.sh "$mode"
done
for mode in configured copy; do
	bash build/self-test.sh "$mode"
done
bash fetch/gc-test.sh valid
