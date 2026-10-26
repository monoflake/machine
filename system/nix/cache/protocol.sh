# Slots and pointer validation are shared by builders and consumers.
cache_epoch() { [ -n "$1" ] || return 1; date -u -d "$1" +%s; }
cache_order() {
	local machine=$1 day=$2 builders=$3 b
	while read -r b; do
		printf '%s %s %s\n' "$(jq -r --arg b "$b" '.[$b]' <<<"$builders")" \
			"$(printf '%s' "$machine:$day:$b" | sha256sum | cut -d ' ' -f 1)" "$b"
	done < <(jq -r 'keys[]' <<<"$builders") | sort -k1,1n -k2,2 | awk '{print $3}'
}
cache_pointer() {
	local file=$1 machine=$2 now=$3
	jq -e 'type == "object"' "$file" >/dev/null 2>&1 || { echo "malformed pointer" >&2; return 1; }
	[ "$(jq -r .machine "$file")" = "$machine" ] || { echo "written for another machine" >&2; return 1; }
	cache_record_valid "$file" "$now"
}
cache_record_valid() {
	local file=$1 now=$2 at path epoch
	jq -e 'type == "object"' "$file" >/dev/null 2>&1 || { echo "malformed record" >&2; return 1; }
	path=$(jq -r .path "$file")
	at=$(jq -r .at "$file")
	[[ $path =~ ^/nix/store/[0-9a-z]{32}-[0-9A-Za-z+._?=-]+$ ]] || { echo "malformed path" >&2; return 1; }
	[[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo "malformed time" >&2; return 1; }
	epoch=$(cache_epoch "$at" 2>/dev/null) || { echo "malformed time" >&2; return 1; }
	((epoch <= now + 3600)) || { echo "more than one hour ahead of its clock" >&2; return 1; }
}
cache_record() {
	local at=$1 path=$2 destination=$3
	jq -n --arg at "$at" --arg path "$path" '{at: $at, path: $path}' >"$destination.new"
	mv "$destination.new" "$destination"
}
