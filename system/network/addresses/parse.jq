# Addresses compare by their words so equivalent IPv6 spellings agree.
def v4:
	if type == "string" and test("^(0|[1-9][0-9]{0,2})([.](0|[1-9][0-9]{0,2})){3}$")
	then split(".") | map(tonumber) | if all(. < 256) then . else null end
	else null end;
def hex:
	ascii_downcase | explode
	| reduce .[] as $c (0; . * 16 + if $c > 96 then $c - 87 else $c - 48 end);
def v6:
	if type != "string" then null
	else split("::") as $halves
		| ($halves | map(if . == "" then [] else split(":") end)) as $parts
		| ($parts | flatten) as $groups
		| ($groups[-1] // "" | v4) as $dotted
		| (if $dotted then $groups[:-1] else $groups end) as $hex
		| (($hex | length) + if $dotted then 2 else 0 end) as $size
		| if ($halves | length) > 2
			or ($hex | any(test("^[0-9A-Fa-f]{1,4}$") | not))
			or ($dotted != null and (endswith($groups[-1]) | not))
			or (if ($halves | length) == 2 then $size >= 8 else $size != 8 end)
		then null
		else ($parts[0] | length) as $left
			| ($hex | map(hex)) as $words
			| (if $dotted then [$dotted[0] * 256 + $dotted[1],
				$dotted[2] * 256 + $dotted[3]] else [] end) as $tail
			| if ($halves | length) == 1 then $words + $tail
				else $words[:$left] + [range(8 - $size) | 0] + $words[$left:] + $tail end
		end
	end;
def address($family):
	. as $text | (if $family == "v4" then v4 else v6 end) as $words
	| if $words then {address: ($text | ascii_downcase), words: $words} else null end;
def endpoint($family):
	if type != "string" then null
	elif . == "" then ""
	else (if $family == "v4" then
		try capture("^(?<address>[^:]+):(?<port>[0-9]+)$") catch null
	else
		try capture("^\\[(?<address>[^]]+)\\]:(?<port>[0-9]+)$") catch null
	end) as $endpoint
	| if $endpoint and ($endpoint.port | tonumber) <= 65535
		then $endpoint.address | address($family) else null end
	end;
