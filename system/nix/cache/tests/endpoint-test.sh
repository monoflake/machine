#!/usr/bin/env bash
# ../endpoint.sh's endpoint_host, each form MACHINE_CACHE_ENDPOINT is given in and each it refuses.
set -o errexit -o nounset -o pipefail
# shellcheck source=system/nix/cache/endpoint.sh
. "$(dirname "$0")/../endpoint.sh"

host=example.com
bucket=caches
failed=0
taken=0
refused=0

# A value taken as the host it names, or as the host and port given second.
takes() {
	local got want=${2:-$host}
	taken=$((taken + 1))
	got=$(MACHINE_CACHE_ENDPOINT=$1 endpoint_host "$bucket") || got="(refused)"
	if [ "$got" != "$want" ]; then
		echo "endpoint_host: '$1' gave '$got', not '$want'" >&2
		failed=1
	fi
}

# A value refused by the variable's name alone, neither the value nor the host in the message.
refuses() {
	local said
	refused=$((refused + 1))
	if said=$(MACHINE_CACHE_ENDPOINT=$1 endpoint_host "$bucket" 2>&1); then
		echo "endpoint_host: '$1' taken, not refused" >&2
		failed=1
	elif [[ $said != *MACHINE_CACHE_ENDPOINT* || $said == *"$host"* ]] ||
		{ [ -n "$1" ] && [[ $said == *"$1"* ]]; }; then
		echo "endpoint_host: '$1' refused as '$said', not by the variable's name alone" >&2
		failed=1
	fi
}

takes "$host"
takes "$host/"
takes "https://$host"
takes "https://$host/"
takes "HTTPS://$host"
takes "https://$host:443" "$host:443"
takes "https://$host/$bucket"
takes "https://$host/$bucket/"
takes "$host "
takes "https://$host"$'\n'
refuses "http://$host"
refuses "s3://$host"
refuses "https://$host/other"
refuses "https://$host/$bucket/other"
refuses "https://$host//"
refuses "https://$host/$bucket/$bucket"
refuses "https://$host?x=1"
refuses "https://$host#x"
refuses "https://user@$host"
refuses "$host&scheme=http"
refuses "$host other"
refuses "https://$host:"
refuses "https://"
refuses ""

[ "$failed" = 0 ] && echo "endpoint_host: $taken forms taken, $refused refused"
exit "$failed"
