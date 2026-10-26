# The machine's static addresses read from its provider's seed for networkd, each rendering kept
# as the archive a failed read falls back to while failing the unit, docs/network.md.
networks=${MACHINE_SEED_NETWORKS:-/run/systemd/network}
archive=${MACHINE_SEED_ARCHIVE:-/var/lib/machine/seed-network}
seed=/dev/disk/by-label/cidata
# Under /run, a tmpfs before any local file system is mounted.
work=$(mktemp -d "${TMPDIR:-/run}/machine-seed.XXXXXX")
mounted=
partial=

clean() {
	[ -z "$partial" ] || rm -f "$partial"
	if [ -n "$mounted" ] && ! umount "$work/seed"; then
		echo "machine-seed-network: the seed stays mounted on $work/seed" >&2
		return
	fi
	rm -rf "$work"
}
trap clean EXIT

# A file written whole beside its name and renamed onto it, so nothing reads it half written.
put() {
	partial=$(mktemp "${2%/*}/.${2##*/}.XXXXXX")
	cp "$1" "$partial"
	chmod "$3" "$partial"
	mv -f "$partial" "$2"
	partial=
}

# The archive given to networkd where there is one, the unit failing either way.
fallback() {
	if [ -f "$archive" ]; then
		mkdir -p "$networks"
		put "$archive" "$networks/10-seed.network" 0644
		echo "machine-seed-network: $1, archive used" >&2
	else
		echo "machine-seed-network: $1 and no archive, nothing written" >&2
	fi
	exit 1
}

if ! udevadm wait --timeout=30 "$seed"; then
	fallback "seed missing"
fi
mkdir "$work/seed"
if ! mount -t iso9660 -o ro "$seed" "$work/seed"; then
	fallback "seed unreadable"
fi
mounted=1
if ! machine-seed-render "$work/seed" "$work/network"; then
	fallback "seed malformed"
fi
if umount "$work/seed"; then
	mounted=
fi

mkdir -p "$networks"
put "$work/network" "$networks/10-seed.network" 0644
# Created private where missing; an existing directory keeps the mode its owner gave it.
[ -d "${archive%/*}" ] || mkdir -m 0700 "${archive%/*}"
put "$work/network" "$archive" 0600
echo "machine-seed-network: seed read and archived"
