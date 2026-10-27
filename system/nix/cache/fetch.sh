# A fetched machine's daily upgrade, docs/cache.md. Its pointer fetched and verified, the paths it
# lacks taken from the bucket and upstream on their keys alone, and the system switched to.
given=$MACHINE_CACHE_CONFIG
field() { jq -r "$1" "$given"; }
bucket=$(field .bucket)
machine=$(field .machine)
applied=${MACHINE_CACHE_APPLIED:-/var/lib/machine/cache-applied}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

refuse() {
	echo "machine-cache: pending/$machine refused, $1" >&2
	exit 1
}

# An object of the bucket written to a file, or status 2 where there is none.
if [[ $bucket == /* ]]; then
	substituter="file://$bucket"
	get() {
		[ -f "$bucket/$1" ] || return 2
		cp "$bucket/$1" "$2"
	}
else
	# Nix's s3:// store takes the endpoint as its host with the scheme apart, as its manual shows.
	endpoint=$(endpoint_host "$bucket") || exit 1
	substituter="s3://$bucket?endpoint=$endpoint&scheme=https&region=auto"
	get() {
		local code
		code=$(curl --silent --show-error --output "$2" --write-out '%{http_code}' \
			--aws-sigv4 aws:amz:auto:s3 -K <(printf 'user = "%s:%s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY") \
			"https://$endpoint/$bucket/$1")
		case $code in
		200) ;;
		404) return 2 ;;
		*)
			echo "machine-cache: $1 answered $code" >&2
			return 1
			;;
		esac
	}
fi

now=$(date -u +%s)
last=$(cat "$applied" 2>/dev/null || true)
last_at=$(jq -r '.at // empty' <<<"$last" 2>/dev/null || printf '%s' "$last")
newest=""
failed=false
consider() {
	local object=$1 signers=$2 status=0 at reason
	get "$object" "$work/candidate" || status=$?
	[ "$status" != 2 ] || return 0
	if [ "$status" != 0 ]; then
		echo "machine-cache: pointer $object read failed with status $status" >&2
		failed=true
		return 0
	fi
	status=0
	get "$object.sig" "$work/candidate.sig" || status=$?
	if [ "$status" != 0 ]; then
		echo "machine-cache: signature $object.sig read failed with status $status" >&2
		failed=true
		return 0
	fi
	if ! ssh-keygen -Y verify -f "$signers" -I builder -n machine-cache \
		-s "$work/candidate.sig" <"$work/candidate" >/dev/null 2>&1; then
		echo "machine-cache: pointer $object refused, invalid signature" >&2
		failed=true
		return 0
	fi
	if ! reason=$(cache_pointer "$work/candidate" "$machine" "$now" 2>&1); then
		echo "machine-cache: pointer $object refused, $reason" >&2
		failed=true
		return 0
	fi
	at=$(jq -r .at "$work/candidate")
	if [[ $at > $last_at && $at > $newest ]]; then
		newest=$at
		cp "$work/candidate" "$work/pointer"
	fi
}
while read -r entry; do
	builder=$(jq -r '.name // empty' <<<"$entry")
	[ -n "$builder" ] || continue
	consider "pending/$machine/$builder" "$(jq -r .signers <<<"$entry")"
done < <(jq -c '.builders[]' "$given")
legacy_signers=$(field '.signers // empty')
[ -z "$legacy_signers" ] || consider "pending/$machine" "$legacy_signers"

if [ -z "$newest" ]; then
	if [ "$failed" = true ]; then
		if [ "${MACHINE_CACHE_FALLBACK:-false}" = true ]; then exit 3; fi
		exit 1
	fi
	if [ "${MACHINE_CACHE_FALLBACK:-false}" = true ]; then exit 2; fi
	if [ -n "$last_at" ]; then
		last_epoch=$(cache_epoch "$last_at") || refuse "last applied time malformed"
	else
		# A new installation gets two days to receive its first answer.
		started=${MACHINE_CACHE_STARTED:-/var/lib/machine/cache-started}
		[ -f "$started" ] || date -u +%Y-%m-%dT%H:%M:%SZ >"$started"
		last_epoch=$(cache_epoch "$(cat "$started")")
	fi
	((now - last_epoch < 172800)) || refuse "nothing applied for two days"
	exit 0
fi
path=$(jq -r .path "$work/pointer")
substituters=$substituter
upstream=$(field '.substituters // empty')
[ -z "$upstream" ] || substituters+=" $upstream"
# Realized even when already valid, the system is rooted in the work directory until the profile
# holds it, docs/store.md.
nix-store --realise "$path" --add-root "$work/system" \
	--option substituters "$substituters" \
	--option trusted-public-keys "$(field .trusted)" \
	--option require-sigs true \
	--option narinfo-cache-negative-ttl 0 >/dev/null || exit 1
if [ "$(readlink /run/current-system)" != "$path" ]; then
	nix-env -p /nix/var/nix/profiles/system --set "$path" || exit 1
	"$path/bin/switch-to-configuration" switch || exit 1
fi
cache_record "$newest" "$path" "$applied"
echo "machine-cache: $machine applied $path, written at $newest"
