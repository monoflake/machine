# The bucket's endpoint as its host and any port, from MACHINE_CACHE_ENDPOINT given as its URL,
# the bucket as its path or not, or its host alone, docs/cache.md. A refusal never names the value.
endpoint_host() {
	local e=${MACHINE_CACHE_ENDPOINT:-}
	e=${e#"${e%%[![:space:]]*}"}
	e=${e%"${e##*[![:space:]]}"}
	e=${e%/}
	e=${e%/"$1"}
	case $e in
	[Hh][Tt][Tt][Pp][Ss]://*) e=${e#*://} ;;
	*://*)
		echo "machine-cache: MACHINE_CACHE_ENDPOINT has a scheme other than https" >&2
		return 1
		;;
	esac
	if ! [[ $e =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
		echo "machine-cache: MACHINE_CACHE_ENDPOINT is no endpoint's URL or host" >&2
		return 1
	fi
	printf '%s\n' "$e"
}
