# A fetched machine's daily upgrade, docs/cache.md. Its pointer fetched and verified, the paths it
# lacks taken from the bucket on its builders' keys alone, and the system switched to.
given=$MACHINE_CACHE_CONFIG
field() { jq -r "$1" "$given"; }
bucket=$(field .bucket)
machine=$(field .machine)
applied=/var/lib/machine/cache-applied
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
		[ -e "$bucket/$1" ] || return 2
		cp "$bucket/$1" "$2"
	}
else
	substituter="s3://$bucket?endpoint=$MACHINE_CACHE_ENDPOINT&region=auto"
	get() {
		local code
		code=$(curl --silent --show-error --output "$2" --write-out '%{http_code}' \
			--aws-sigv4 aws:amz:auto:s3 -K <(printf 'user = "%s:%s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY") \
			"https://$MACHINE_CACHE_ENDPOINT/$bucket/$1")
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

status=0
get "pending/$machine" "$work/pointer" || status=$?
if [ "$status" = 2 ]; then
	echo "machine-cache: no pointer for $machine, nothing to do"
	exit 0
fi
[ "$status" = 0 ] || exit 1
get "pending/$machine.sig" "$work/pointer.sig" || refuse "its signature missing"
ssh-keygen -Y verify -f "$(field .signers)" -I builder -n machine-cache \
	-s "$work/pointer.sig" <"$work/pointer" >/dev/null || refuse "signed by none of its builders"

[ "$(jq -r .machine "$work/pointer")" = "$machine" ] || refuse "written for another machine"
path=$(jq -r .path "$work/pointer")
at=$(jq -r .at "$work/pointer")
[[ $path =~ ^/nix/store/[0-9a-z]{32}-[0-9A-Za-z+._?=-]+$ ]] || refuse "its path malformed"
[[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || refuse "its time malformed"
last=$(cat "$applied" 2>/dev/null || true)
if [ "$at" = "$last" ]; then
	echo "machine-cache: pending/$machine of $at applied already, nothing to do"
	exit 0
fi
[ -z "$last" ] || [[ $at > $last ]] || refuse "written at $at, before $last applied"

nix-store --realise "$path" \
	--option substituters "$substituter" \
	--option trusted-public-keys "$(field .trusted)" \
	--option require-sigs true \
	--option narinfo-cache-negative-ttl 0 >/dev/null
nix-env -p /nix/var/nix/profiles/system --set "$path"
"$path/bin/switch-to-configuration" switch
echo "$at" >"$applied"
echo "machine-cache: $machine switched to $path, written at $at"
