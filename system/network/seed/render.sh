# The seed's network-config, netplan's version 2 with one ethernet, rendered as one networkd
# .network file; any other shape is refused by name and nothing is written, docs/network.md.
if [ $# != 2 ]; then
	echo "machine-seed-render: give the seed's directory and the file to write" >&2
	exit 2
fi
config=$1/network-config
if [ ! -f "$config" ]; then
	echo "machine-seed-render: the seed holds no network-config, refused" >&2
	exit 1
fi
if ! json=$(yq --output-format=json . "$config"); then
	echo "machine-seed-render: network-config is not YAML, refused" >&2
	exit 1
fi

# An address is its family, its words of eight bits for IPv4 or sixteen for IPv6, and any prefix.
# shellcheck disable=SC2016
program='
def refuse($m): "machine-seed-render: network-config \($m), refused\n" | halt_error(1);
def need(f; $m): if f then . else refuse($m) end;
def hex:
	ascii_downcase | explode
	| reduce .[] as $c (0; . * 16 + if $c > 96 then $c - 87 else $c - 48 end);
def v4:
	if test("^(0|[1-9][0-9]{0,2})([.](0|[1-9][0-9]{0,2})){3}$")
	then split(".") | map(tonumber) | if all(. < 256) then . else null end
	else null end;
def v6:
	if test("^[0-9A-Fa-f:]+$") | not then null
	else split("::") as $h | ($h | map(if . == "" then [] else split(":") end)) as $p
		| ($p | map(length) | add) as $n
		| if ($h | length) > 2 or ($p | flatten | any(test("^[0-9A-Fa-f]{1,4}$") | not)) then null
			elif ($h | length) == 1 then if $n == 8 then $p[0] | map(hex) else null end
			elif $n < 8 then $p[0] + [range(8 - $n) | "0"] + $p[1] | map(hex)
			else null end
	end;
def address:
	if type != "string" then null
	elif v4 then {family: 4, width: 8, words: v4}
	elif v6 then {family: 6, width: 16, words: v6}
	else null end;
def prefixed:
	if type == "string" and test("^[^/]+/(0|[1-9][0-9]{0,2})$") then
		split("/") as [$a, $p] | ($a | address) as $x
		| if $x and ($p | tonumber) <= ($x.words | length) * $x.width
			then $x + {prefix: ($p | tonumber)} else null end
	else null end;
def within($n):
	. as $g | all(range($n.words | length); ($n.width * .) as $s
		| if $n.prefix >= $s + $n.width then $g.words[.] == $n.words[.]
			elif $n.prefix <= $s then true
			else pow(2; $s + $n.width - $n.prefix) as $d
				| ($g.words[.] / $d | floor) == ($n.words[.] / $d | floor) end);
def gateway($at; $nets; $key; $family):
	if has($key) then .[$key] as $text | $text | address
		| need(. != null and .family == $family;
			"\($at).\($key) \($text | tojson) is no IPv\($family) address")
		| need(. as $g | any($nets[]; .family == $family and (. as $n | $g | within($n)));
			"\($at).\($key) \($text) lies inside no prefix of an IPv\($family) address")
		| $text
	else empty end;

need(length == 1; "holds \(length) documents, not one") | .[0]
| need(type == "object"; "is not a map")
| need(.version == 2; "is version \(.version | tojson), not 2")
| (keys_unsorted - ["version", "ethernets"]) as $extra
| need($extra == []; "holds \($extra | join(" and ")), which is not read")
| .ethernets
| need(type == "object" and length == 1;
	"holds \(if type == "object" then length else 0 end) ethernets, not one")
| (keys_unsorted[0]) as $name | .[$name] | "ethernets.\($name)" as $at
| need(type == "object"; "\($at) is not a map")
| (keys_unsorted - ["match", "set-name", "dhcp4", "dhcp6", "addresses", "nameservers",
	"gateway4", "gateway6"]) as $extra
| need($extra == []; "\($at) holds \($extra | join(" and ")), which is not read")
| need(.match | type == "object" and keys == ["macaddress"]; "\($at).match is not macaddress alone")
| need(.match.macaddress | type == "string" and test("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$");
	"\($at).match.macaddress is no MAC address")
| need((has("set-name") | not) or (.["set-name"] | type == "string"); "\($at).set-name is no name")
| need((.dhcp4 // false) == false; "\($at).dhcp4 is not false")
| need((.dhcp6 // false) == false; "\($at).dhcp6 is not false")
| need((has("nameservers") | not) or (.nameservers | type == "object" and keys == ["addresses"]
	and (.addresses | type == "array" and all(type == "string")));
	"\($at).nameservers holds more than a list of addresses")
| need(.addresses | type == "array" and length > 0; "\($at).addresses is no list of addresses")
| [.addresses[] | . as $a | prefixed
	| need(. != null; "\($at).addresses has \($a | tojson), no address with its prefix length")
] as $nets
| [
	"[Match]",
	"MACAddress=\(.match.macaddress)",
	"[Network]",
	"DHCP=no",
	"IPv6AcceptRA=no",
	(.addresses[] | "Address=\(.)"),
	(gateway($at; $nets; "gateway4"; 4), gateway($at; $nets; "gateway6"; 6) | "Gateway=\(.)")
] | join("\n")
'
network=$(jq --raw-output --slurp "$program" <<<"$json") || exit 1
printf '%s\n' "$network" >"$2"
