#!/usr/bin/env bash
# The seed's tests, the renderer's and the unit's paths, the first failure stopping them,
# docs/network.md.
set -o errexit -o nounset -o pipefail
cd "$(dirname "$0")"
bash render-test.sh
