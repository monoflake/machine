umask 077
say() { echo "update: $*"; }
refuse() {
	say "refused, $1" >&2
	exit 1
}
dry=false
instance=system
case ${1:-} in
system | driver) instance=$1; shift ;;
esac
if [ "${1:-}" = --dry-run ]; then
	dry=true
	shift
fi
[ "$#" = 0 ] || refuse 'unsupported instance or argument'
given=$MACHINE_UPDATE_CONFIG
field() { jq -r "$1" "$given"; }
bucket=$(field .bucket)
machine=$(field .machine)
state=${STATE_DIRECTORY:?}/accepted.json
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
say 'reading runtime access files'
endpoint=$(cat "$(field .endpointFile)" 2>/dev/null) || refuse 'endpoint file unavailable'
credentials=$(field .credentialsFile)
[ "${AWS_SHARED_CREDENTIALS_FILE:-}" = "$credentials" ] || refuse 'credentials file path differs'
credential() {
	awk -v wanted="$1" '
		{ sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
		/^\[/ { active = ($0 == "[systems]"); next }
		active && /^[^#;][^=]*=/ {
			key = $0; sub(/=.*/, "", key); gsub(/[ \t]+$/, "", key)
			if (key == wanted) { sub(/^[^=]*=[ \t]*/, ""); print; found++ }
		}
		END { if (found != 1) exit 1 }
	' "$credentials" 2>/dev/null
}
access=$(credential aws_access_key_id) || refuse 'systems credentials malformed'
secret=$(credential aws_secret_access_key) || refuse 'systems credentials malformed'
[[ $access =~ ^[A-Za-z0-9]+$ && $secret =~ ^[A-Za-z0-9/+=]+$ ]] || refuse 'systems credentials malformed'
host=${endpoint#https://}
host=${host%/}
if [[ $bucket == file:///* ]]; then
	get() {
		[ -e "${bucket#file://}/$1" ] || return 2
		cp "${bucket#file://}/$1" "$2" 2>/dev/null
	}
	substituter=$bucket
else
	[[ $bucket =~ ^[a-z0-9][a-z0-9.-]*$ ]] || refuse 'bucket malformed'
	[[ $endpoint =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || refuse 'endpoint malformed'
	substituter="s3://$bucket?endpoint=$host&scheme=https&region=auto&profile=systems"
	get() {
		local code
		code=$(printf 'user = "%s:%s"\n' "$access" "$secret" |
			curl --silent --output "$2" --write-out '%{http_code}' \
				--aws-sigv4 aws:amz:auto:s3 -K - "https://$host/$bucket/$1" 2>/dev/null) || return 1
		[ "$code" != 404 ] || return 2
		[ "$code" = 200 ]
	}
fi
# A failed tool's last lines, the endpoint's host and the key pair masked as literal text.
masked() {
	local line
	tail -n 5 "$1" | while IFS= read -r line; do
		[ -z "$host" ] || line=${line//"$host"/<endpoint>}
		line=${line//"$access"/<key>}
		printf 'update: %s\n' "${line//"$secret"/<secret>}"
	done >&2
}
verify_pointer() {
	local signers=$1 namespace=$2 principal
	ssh-keygen -Y find-principals -f "$signers" -s "$work/pointer.sig" \
		>"$work/principals" 2>/dev/null || return 1
	while IFS= read -r principal; do
		case $principal in
		ci) ;;
		mac) [ "$namespace" = driver-pointer ] || continue ;;
		*) continue ;;
		esac
		if ssh-keygen -Y verify -f "$signers" -I "$principal" -n "$namespace" \
			-s "$work/pointer.sig" <"$work/pointer" >/dev/null 2>&1; then return 0; fi
	done <"$work/principals"
	return 1
}
record() {
	local pending
	pending=$(mktemp "${STATE_DIRECTORY}/.accepted.XXXXXX")
	cp "$work/pointer" "$pending"
	mv -f "$pending" "$state"
	say 'accepted pointer recorded'
}
if [ "$instance" = driver ]; then
	[ "$(field .driverChannel)" = true ] || refuse 'driver channel disabled'
	update_driver
	exit 0
fi
say 'fetching system pointer'
get "pointer/system/$machine" "$work/pointer" || refuse 'pointer fetch failed'
say 'fetching pointer signature'
get "pointer/system/$machine.sig" "$work/pointer.sig" || refuse 'signature fetch failed'
say 'verifying system pointer signature'
verify_pointer "$(field .signers)" system-pointer || refuse 'invalid system-pointer signature'
say 'validating system pointer'
reason=$(update_pointer "$work/pointer" "$machine" "$(date -u +%s)") || refuse "$reason"
at=$(jq -r .at "$work/pointer")
run=$(jq -r .run "$work/pointer")
path=$(jq -r .path "$work/pointer")
taken=false
if [ -f "$state" ]; then
	update_pointer "$state" "$machine" "$(date -u +%s)" >/dev/null || refuse 'recorded state malformed'
	last_at=$(jq -r .at "$state")
	last_run=$(jq -r .run "$state")
	[[ ! $at < $last_at ]] || refuse 'older at than accepted pointer'
	if [ "$at" = "$last_at" ]; then
		[ "$run" = "$last_run" ] || refuse 'equal at from another run'
		[ "$path" = "$(jq -r .path "$state")" ] || refuse 'accepted run changed path'
		taken=true
		say 'pointer already taken'
	fi
fi
say 'reading the running system'
current=$(readlink /run/current-system) || refuse 'running system unavailable'
if [ "$current" = "$path" ]; then
	say 'pointer is the running system'
	if [ "$dry" = false ] && [ "$taken" = false ]; then record; fi
	exit 0
fi
say 'pointer differs from the running system'
if [ "$taken" = true ]; then
	say 'accepted pointer would not switch again'
	exit 0
fi
if [ "$dry" = true ]; then
	say 'dry run would switch to pointer system'
	exit 0
fi
say 'realising system without builds'
nix-store --realise "$path" --add-root "$work/system" \
	--option substituters "https://cache.nixos.org $substituter" \
	--option trusted-public-keys "$(field .trusted)" \
	--option require-sigs true --option max-jobs 0 --option builders "" \
	--option narinfo-cache-negative-ttl 0 >"$work/realise-log" 2>&1 || {
	masked "$work/realise-log"
	refuse 'realise failed'
}
say 'setting system profile'
nix-env -p /nix/var/nix/profiles/system --set "$path" >"$work/profile-log" 2>&1 || refuse 'profile update failed'
say 'switching system'
if ! "$path/bin/switch-to-configuration" switch >"$work/switch-log" 2>&1; then
	masked "$work/switch-log"
	say 'switch failed, restoring previous system'
	nix-env -p /nix/var/nix/profiles/system --set "$current" >"$work/restore-profile-log" 2>&1 ||
		refuse 'switch failed and profile restoration failed'
	"$current/bin/switch-to-configuration" switch >"$work/restore-switch-log" 2>&1 ||
		refuse 'switch failed and system restoration failed'
	refuse 'switch failed'
fi
record
say 'system switch succeeded'
