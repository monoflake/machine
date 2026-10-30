update_epoch() { [ -n "$1" ] || return 1; date -u -d "$1" +%s; }
update_pointer() {
	local file=$1 machine=$2 now=$3 at path epoch
	jq -e 'type == "object" and keys == ["at", "machine", "path", "run"] and all(.[]; type == "string")' \
		"$file" >/dev/null 2>&1 || { echo 'malformed pointer fields'; return 1; }
	[ "$(jq -r .machine "$file")" = "$machine" ] || { echo 'written for another machine'; return 1; }
	path=$(jq -r .path "$file")
	at=$(jq -r .at "$file")
	[[ $path =~ ^/nix/store/[0-9a-z]{32}-[0-9A-Za-z+._?=-]+$ ]] || { echo 'malformed path'; return 1; }
	[[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo 'malformed time'; return 1; }
	epoch=$(update_epoch "$at" 2>/dev/null) || { echo 'malformed time'; return 1; }
	[ "$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)" = "$at" ] || { echo 'malformed time'; return 1; }
	((epoch <= now + 3600)) || { echo 'more than one hour ahead of its clock'; return 1; }
	jq -e '.run | length > 0 and (explode | all(. >= 32 and . != 127))' "$file" >/dev/null \
		|| { echo 'malformed run'; return 1; }
}
