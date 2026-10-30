#!/usr/bin/env bash
# render.sh over the seed it takes and each shape it refuses, then boot.sh's paths with udevadm,
# mount and umount faked, yq-go and jq taken from the flake's pinned nixpkgs.
set -o errexit -o nounset -o pipefail
here=$(cd "$(dirname "$0")" && pwd)

# Nix reads a copy of the flake, as git's index lacks what jj adds, the workspace's docs/lessons.md.
# TMPDIR is given again, as nix shell drops it.
if [ -z "${MACHINE_SEED_TOOLS:-}" ]; then
	t=$(realpath "$(mktemp -d)")
	trap 'rm -rf "$t"' EXIT
	cp "$here/../../../flake.nix" "$here/../../../flake.lock" "$t/"
	nix shell --inputs-from "path:$t" nixpkgs#yq-go nixpkgs#jq \
		-c env MACHINE_SEED_TOOLS=1 ${TMPDIR:+TMPDIR="$TMPDIR"} bash "$0"
	exit
fi

tmp=$(realpath "$(mktemp -d)")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export PATH=$tmp/bin:$PATH FAKE_CALLS=$tmp/calls
# The renderer as writeShellApplication runs it.
cat >"$tmp/bin/machine-seed-render" <<EOF
#!/usr/bin/env bash
exec bash -o errexit -o nounset -o pipefail "$here/render.sh" "\$@"
EOF
# The seed there while FAKE_SEED names a directory, and unreadable while FAKE_UNREADABLE is set.
cat >"$tmp/bin/udevadm" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "wait --timeout=30 /dev/disk/by-label/cidata" ] && [ -n "${FAKE_SEED:-}" ]
EOF
cat >"$tmp/bin/mount" <<'EOF'
#!/usr/bin/env bash
[ "${*:1:5}" = "-t iso9660 -o ro /dev/disk/by-label/cidata" ] || exit 32
[ -z "${FAKE_UNREADABLE:-}" ] || exit 32
cp -R "$FAKE_SEED/." "$6/"
echo mount >>"$FAKE_CALLS"
EOF
cat >"$tmp/bin/umount" <<'EOF'
#!/usr/bin/env bash
find "$1" -mindepth 1 -delete
echo umount >>"$FAKE_CALLS"
EOF
chmod +x "$tmp/bin/"*

seed='version: 2
ethernets:
  "eth0":
    match:
      macaddress: "00:00:5e:00:53:01"
    set-name: "eth0"
    dhcp4: false
    dhcp6: false
    addresses:
      - 192.0.2.10/24
      - 2001:db8::10/64
    nameservers:
      addresses:
        - "192.0.2.53"
        - "192.0.2.54"
        - "192.0.2.55"
    gateway4: 192.0.2.1
    gateway6: 2001:db8::1'
rendered='[Match]
MACAddress=00:00:5e:00:53:01
[Network]
DHCP=no
IPv6AcceptRA=no
Address=192.0.2.10/24
Address=2001:db8::10/64
Gateway=192.0.2.1
Gateway=2001:db8::1'
failed=0
taken=0
refused=0
cases=0

nl=$'\n'

# A seed directory holding the network-config given.
seeded() {
	rm -rf "$tmp/seed"
	mkdir "$tmp/seed"
	printf '%s\n' "$1" >"$tmp/seed/network-config"
}

# A network-config rendered as the .network file given.
takes() {
	taken=$((taken + 1))
	seeded "$1"
	rm -f "$tmp/out"
	if ! machine-seed-render "$tmp/seed" "$tmp/out" 2>"$tmp/said"; then
		echo "render: $3 refused, $(cat "$tmp/said")" >&2
		failed=1
	elif [ "$(cat "$tmp/out")" != "$2" ]; then
		printf 'render: %s gave\n%s\nnot\n%s\n' "$3" "$(cat "$tmp/out")" "$2" >&2
		failed=1
	fi
}

# The seed directory as it stands refused naming the part given, and no file written.
refused() {
	refused=$((refused + 1))
	rm -f "$tmp/out"
	if machine-seed-render "$tmp/seed" "$tmp/out" 2>"$tmp/said"; then
		echo "render: $2 taken, not refused" >&2
		failed=1
	elif [ -e "$tmp/out" ]; then
		echo "render: $2 refused, but a file written" >&2
		failed=1
	elif ! grep -qF -- "$1" "$tmp/said"; then
		echo "render: $2 refused as '$(cat "$tmp/said")', not naming '$1'" >&2
		failed=1
	fi
}

# A network-config refused naming the part given.
refuses() {
	seeded "$1"
	refused "$2" "$3"
}

takes "$seed" "$rendered" "the provider's seed"
takes "${seed/"    gateway6: 2001:db8::1"/}" "${rendered/"${nl}Gateway=2001:db8::1"/}" "no gateway6"
upper=${seed//192.0.2.10\/24/192.0.2.130/25}
upper_rendered=${rendered//192.0.2.10\/24/192.0.2.130/25}
takes "${upper/192.0.2.1$nl/192.0.2.129$nl}" "${upper_rendered/=192.0.2.1$nl/=192.0.2.129$nl}" \
	"a /25 whose gateway lies in its upper half"
takes "${seed//2001:db8::10\/64/2001:db8:0:ff::10/56}" \
	"${rendered//2001:db8::10\/64/2001:db8:0:ff::10/56}" "a /56 holding its gateway"
takes "${seed/dhcp6: false/\"dhcp6\": false}" "$rendered" "a quoted key"
refuses "${seed/"    gateway6:"/"    routes: []$nl    gateway6:"}" "routes" "a routes key"
refuses "$seed$nl  eth1:$nl    match:$nl      macaddress: \"00:00:5e:00:53:02\"" "2 ethernets" \
	"two ethernets"
refuses "version: 2${nl}ethernets: {}" "0 ethernets" "no ethernet"
refuses "${seed/dhcp4: false/dhcp4: true}" "dhcp4" "dhcp4 true"
refuses "${seed/dhcp6: false/dhcp6: true}" "dhcp6" "dhcp6 true"
refuses "${seed/192.0.2.10\/24/192.0.2.10}" '"192.0.2.10"' "an address with no prefix"
refuses "${seed/192.0.2.10\/24/192.0.2.10/33}" '"192.0.2.10/33"' "a prefix past 32"
refuses "${seed/2001:db8::10\/64/2001:db8::10:1:2:3:4:5:6/64}" "2001:db8::10:1:2:3:4:5:6/64" \
	"an IPv6 address of nine groups"
refuses "${seed/gateway4: 192.0.2.1/gateway4: 198.51.100.1}" "gateway4 198.51.100.1" \
	"gateway4 off its prefix"
refuses "${seed//192.0.2.10\/24/192.0.2.130/25}" "gateway4 192.0.2.1" \
	"gateway4 in the lower half of a /25"
refuses "${seed/gateway6: 2001:db8::1/gateway6: 2001:db8:1::1}" "gateway6 2001:db8:1::1" \
	"gateway6 off its prefix"
refuses "${seed/gateway4: 192.0.2.1/gateway4: 2001:db8::1}" "gateway4" "gateway4 an IPv6 address"
refuses "${seed/"gateway6: 2001:db8::1"/"gateway6:$nl      - 2001:db8::1"}" "gateway6" \
	"gateway6 a list"
refuses "version: 1
config:
  - type: physical
    name: eth0
    mac_address: \"00:00:5e:00:53:01\"
    subnets:
      - type: static
        address: 192.0.2.10/24
        gateway: 192.0.2.1" "version 1" "version 1"
refuses "renderer: networkd$nl$seed" "renderer" "an unknown key at the top"
refuses "${seed/"    dhcp4:"/"    mtu: 1500$nl    dhcp4:"}" "mtu" "an unknown key in the ethernet"
refuses "${seed/"      macaddress:"/"      name: eth0$nl      macaddress:"}" "match" \
	"a match by name beside the MAC"
refuses "${seed/00:00:5e:00:53:01/00:00:5e:00:53}" "macaddress" "a MAC of five octets"
refuses "${seed/"    gateway4:"/"      search: [example.com]$nl    gateway4:"}" "nameservers" \
	"a nameservers search"
refuses "${seed/"    dhcp4:"/"	dhcp4:"}" "not YAML" "a tab"
refuses "$seed$nl---$nl$seed" "2 documents" "two documents"
refuses "" "network-config" "an empty network-config"
seeded ""
rm "$tmp/seed/network-config"
refused "no network-config" "a seed with no network-config"

archived=${rendered/192.0.2.10/192.0.2.20}
network=$tmp/run/systemd/network/10-seed.network
archive=$tmp/state/machine/seed-network

# boot.sh run once with an archive or none, its directories fresh, the seed as FAKE_SEED gives it.
boot() {
	cases=$((cases + 1))
	rm -rf "$tmp/run" "$tmp/state" "$tmp/scratch"
	mkdir -p "$tmp/scratch" "$tmp/state"
	if [ "$1" = archived ]; then
		mkdir "$tmp/state/machine"
		printf '%s\n' "$archived" >"$archive"
	fi
	: >"$FAKE_CALLS"
	status=0
	TMPDIR=$tmp/scratch MACHINE_SEED_NETWORKS=${network%/*} MACHINE_SEED_ARCHIVE=$archive \
		bash -o errexit -o nounset -o pipefail "$here/boot.sh" >"$tmp/said" 2>&1 || status=$?
}

# Each fact the run named by the first argument is held to, the rest of the arguments in pairs.
holds() {
	local run=$1 got want
	shift
	while [ $# -gt 0 ]; do
		got=$1 want=$2
		shift 2
		if [ "$got" != "$want" ]; then
			printf 'boot: %s gave\n%s\nnot\n%s\nsaying %s\n' "$run" "$got" "$want" "$(said)" >&2
			failed=1
		fi
	done
}
listed() {
	[ ! -d "${network%/*}" ] || (cd "${network%/*}" && find . -mindepth 1 | sed 's|^\./||') |
		tr '\n' ' '
}
# shellcheck disable=SC2012
mode() { ls -ld "$1" | cut -c1-10; }
said() { tr '\n' ' ' <"$tmp/said"; }
calls() { tr '\n' ' ' <"$FAKE_CALLS"; }
left() { find "$tmp/scratch" -mindepth 1; }

seeded "$seed"
FAKE_SEED=$tmp/seed boot none
holds "a seed read" "$status" 0 "$(said)" "machine-seed-network: seed read and archived " \
	"$(cat "$network")" "$rendered" "$(listed)" "10-seed.network " "$(mode "$network")" "-rw-r--r--" \
	"$(cat "$archive")" "$rendered" "$(mode "$archive")" "-rw-------" \
	"$(mode "${archive%/*}")" "drwxr-xr-x" "$(calls)" "mount umount " "$(left)" ""

FAKE_SEED='' boot archived
holds "a seed missing" "$status" 1 "$(said)" "machine-seed-network: seed missing, archive used " \
	"$(cat "$network")" "$archived" "$(listed)" "10-seed.network " "$(mode "$network")" "-rw-r--r--" \
	"$(cat "$archive")" "$archived" "$(calls)" "" "$(left)" ""

FAKE_SEED=$tmp/seed FAKE_UNREADABLE=1 boot archived
holds "a seed unreadable" "$status" 1 \
	"$(said)" "machine-seed-network: seed unreadable, archive used " \
	"$(cat "$network")" "$archived" "$(listed)" "10-seed.network " "$(cat "$archive")" "$archived" \
	"$(calls)" "" "$(left)" ""

seeded "${seed/dhcp4: false/dhcp4: true}"
FAKE_SEED=$tmp/seed boot archived
holds "a seed malformed" "$status" 1 \
	"$(listed)" "10-seed.network " "$(cat "$network")" "$archived" \
	"$(cat "$archive")" "$archived" "$(calls)" "mount umount " "$(left)" "" \
	"$(grep -c "seed malformed, archive used" "$tmp/said")" 1

FAKE_SEED=$tmp/seed boot none
holds "a seed malformed and no archive" "$status" 1 \
	"$(listed)" "" "$([ -e "$archive" ] && echo kept)" "" \
	"$(calls)" "mount umount " "$(left)" "" \
	"$(grep -c "seed malformed and no archive, nothing written" "$tmp/said")" 1

FAKE_SEED='' boot none
holds "neither seed nor archive" "$status" 1 \
	"$(said)" "machine-seed-network: seed missing and no archive, nothing written " \
	"$(listed)" "" "$([ -e "$tmp/state/machine" ] && echo made)" "" "$(left)" ""

[ "$failed" = 0 ] && echo "render: $taken seeds taken, $refused refused; boot: $cases paths taken"
[ "$failed" = 0 ] || exit 1
