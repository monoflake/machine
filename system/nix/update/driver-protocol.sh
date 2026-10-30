update_driver_pointer() {
	local file=$1 machine=$2 now=$3 builds=$4 at epoch version
	jq -e 'type == "object" and keys == ["archives","at","machine","run","version"] and
		all(.machine,.at,.run,.version; type == "string") and
		(.archives | type == "object" and keys == ["aarch64-linux","x86_64-linux"] and
		all(.[]; type == "object" and keys == ["sha256","url"] and
			(.url | type == "string") and
			(.sha256 | type == "string" and test("^[0-9a-fA-F]{64}$"))))' \
		"$file" >/dev/null 2>&1 || { echo 'malformed driver pointer fields or archive'; return 1; }
	if [ "$builds" != true ]; then
		jq -e 'all(.archives[]; .url | startswith("https://"))' "$file" >/dev/null ||
			{ echo 'build archives not allowed on this machine'; return 1; }
	fi
	jq -e 'all(.archives[]; (.url | test("^https://[^[:space:]]+$")) or
		.url == ("build/driver/" + .sha256 + ".tar.gz"))' "$file" >/dev/null ||
		{ echo 'malformed driver pointer fields or archive'; return 1; }
	[ "$(jq -r .machine "$file")" = "$machine" ] || { echo 'written for another machine'; return 1; }
	version=$(jq -r .version "$file")
	[[ $version =~ ^[0-9A-Za-z.+-]+$ && $version != . && $version != .. && $version != current && $version != previous ]] ||
		{ echo 'malformed version'; return 1; }
	at=$(jq -r .at "$file")
	[[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo 'malformed time'; return 1; }
	epoch=$(update_epoch "$at" 2>/dev/null) || { echo 'malformed time'; return 1; }
	[ "$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)" = "$at" ] || { echo 'malformed time'; return 1; }
	((epoch <= now + 3600)) || { echo 'more than one hour ahead of its clock'; return 1; }
	jq -e '.run | length > 0 and (explode | all(. >= 32 and . != 127))' "$file" >/dev/null ||
		{ echo 'malformed run'; return 1; }
}
