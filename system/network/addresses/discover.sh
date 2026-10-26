# Each observation keeps the last confirmed address until two changed candidates agree.
state=${MACHINE_ADDRESSES_STATE:-/var/lib/machine/addresses.json}
parser=$(cat "$1")
partial=
trap '[ -z "$partial" ] || rm -f "$partial"' EXIT

old='{}'
if [ -f "$state" ]; then
	old=$(jq -cse 'select(length == 1 and (.[0] | type == "object")) | .[0]' \
		"$state" 2>/dev/null) || old='{}'
fi

observe() {
	local selected=$1 netcheck='null' family flag host source trace reply item url
	local v4='null' v6='null' now
	if reply=$(timeout 20 tailscale netcheck --format=json 2>/dev/null); then
		netcheck=$(jq -cse 'select(length == 1 and (.[0] | type == "object")) | .[0]' \
			<<<"$reply" 2>/dev/null) || netcheck='null'
	fi
	for family in v4 v6; do
		jq -e --arg f "$family" '.[$f]' <<<"$selected" >/dev/null || continue
		flag=-4
		[ "$family" = v4 ] || flag=-6
		host=unknown
		if reply=$(ip -j "$flag" address show scope global 2>/dev/null); then
			host=$(jq -er 'if type != "array" then "unknown"
				elif length == 0 then "none"
				elif all(.[]; .addr_info | type == "array") then
					if any(.[].addr_info[]; .scope == "global") then "present" else "none" end
				else "unknown" end' <<<"$reply" 2>/dev/null) || host=unknown
		fi
		if [ "$host" = none ]; then
			item='{"state":"none","reason":"no host address with global scope"}'
		else
			source=$(jq -c --arg f "$family" "$parser
				(if \$f == \"v4\" then .GlobalV4 else .GlobalV6 end) | endpoint(\$f)" \
				<<<"$netcheck" 2>/dev/null) || source=null
			[ -n "$source" ] || source=null
			trace=null
			if [ "$family" = v4 ]; then
				url=https://1.1.1.1/cdn-cgi/trace
			else
				url='https://[2606:4700:4700::1111]/cdn-cgi/trace'
			fi
			if reply=$(curl --disable "$flag" --noproxy '*' --fail --silent --show-error \
				--connect-timeout 5 --max-time 10 "$url" 2>/dev/null); then
				trace=$(jq -Rsc --arg f "$family" "$parser
					[split(\"\\n\")[] | rtrimstr(\"\\r\") | select(startswith(\"ip=\")) | .[3:]]
					| if length != 1 then null elif .[0] == \"\" then \"\"
					else .[0] | address(\$f) end" <<<"$reply" 2>/dev/null) || trace=null
			fi
			item=$(jq -nc --argjson a "$source" --argjson b "$trace" --arg host "$host" '
				if $a == "" and $b == "" then
					{state: "none", reason: "both sources explicitly report no address"}
				elif $a == null or $b == null then
					{state: "unknown", reason: (if $a == null and $b == null then
						"netcheck and trace unavailable or unparseable"
						elif $a == null then "netcheck unavailable or unparseable"
						else "trace unavailable or unparseable" end)}
				elif $host == "unknown" then
					{state: "unknown", reason: "host addresses unavailable or unparseable"}
				elif ($a | type) == "object" and ($b | type) == "object"
					and $a.words == $b.words then $a + {state: "confirmed", reason: null}
				else {state: "disputed", reason: "netcheck and trace disagree"} end')
		fi
		if [ "$family" = v4 ]; then v4=$item; else v6=$item; fi
	done
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	jq -nc --argjson v4 "$v4" --argjson v6 "$v6" --arg now "$now" \
		'{v4: ($v4 + {checked_at: $now}), v6: ($v6 + {checked_at: $now})}'
}

first=$(observe '{"v4":true,"v6":true}')
pending=$(jq -nc --argjson old "$old" --argjson first "$first" "$parser
	[\"v4\", \"v6\"] | map(. as \$f | {key: \$f, value:
		(\$first[\$f].state == \"confirmed\" and
		(\$old[\$f].address | address(\$f) | .words) != \$first[\$f].words)}) | from_entries")
second='{}'
if jq -e 'any' <<<"$pending" >/dev/null; then
	sleep 60
	second=$(observe "$pending")
fi
result=$(jq -nc --argjson old "$old" --argjson first "$first" \
	--argjson pending "$pending" --argjson second "$second" '
	["v4", "v6"] | map(. as $f | $first[$f] as $a | $second[$f] as $b
		| (if $pending[$f] then
			if $b.state == "confirmed" and $a.words == $b.words then $b
			elif $b.state == "unknown" then $b + {reason: ("second check " + $b.reason)}
			else $b + {state: "disputed", reason: "second check disagrees with first candidate"} end
		else $a end) as $check
		| {key: $f, value: {
			address: (if $check.state == "confirmed" then $check.address else $old[$f].address end),
			state: $check.state,
			confirmed_at: (if $check.state == "confirmed" then $check.checked_at
				else $old[$f].confirmed_at end),
			checked_at: $check.checked_at,
			reason: $check.reason
		}}) | from_entries')

# Only the final rename changes the file a reader sees.
umask 077
mkdir -p "${state%/*}"
partial=$(mktemp "${state%/*}/.${state##*/}.XXXXXX")
printf '%s\n' "$result" >"$partial"
mv -f "$partial" "$state"
partial=
