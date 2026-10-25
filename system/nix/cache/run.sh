# A builder's run for one machine, docs/cache.md. The bucket swept, the machine's system built, the
# paths it lacks uploaded under the cap and the pointer to the system signed last.
machine=$1
given=$MACHINE_CACHE_CONFIG
field() { jq -r "$1" "$given"; }

flake=$(jq -r --arg m "$machine" '.machines[$m].flake // empty' "$given")
[ -n "$flake" ] || {
	echo "machine-cache: $machine is not built here" >&2
	exit 1
}
# One run at a time on a builder, so no two evaluations meet in its memory or its sweeps.
exec 9>/run/lock/machine-cache
flock -w 1800 9 || {
	echo "machine-cache: another run held the lock past 30 minutes" >&2
	exit 1
}
bucket=$(field .bucket)
cap=$(field .cap)
store=$(field '.store // empty')
on=()
[ -z "$store" ] || on=(--store "$store")
from=()
[ -z "$store" ] || from=(--from "$store")
work=$(mktemp -d /var/tmp/machine-cache.XXXXXX)
trap 'rm -rf "$work"' EXIT

# The bucket as rclone reaches it, or the directory standing in for it.
export RCLONE_CONFIG=/dev/null
if [[ $bucket == /* ]]; then
	mkdir -p "$bucket"
	objects=$bucket
else
	export RCLONE_S3_PROVIDER=Cloudflare RCLONE_S3_ENV_AUTH=true RCLONE_S3_NO_CHECK_BUCKET=true
	export RCLONE_S3_ENDPOINT="https://$MACHINE_CACHE_ENDPOINT"
	objects=":s3:$bucket"
fi

# The machine's wrapper asked one of its two questions, through the tailnet where one runs.
ask() {
	local host proxy=()
	host=$(jq -r --arg m "$1" '.machines[$m].host' "$given")
	[ "$(field .tailnet)" != true ] || proxy=(-o "ProxyCommand=tailscale nc %h %p")
	ssh -i "$(field .accessKey)" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=30 \
		-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/var/lib/machine/cache-known-hosts \
		"${proxy[@]}" "machine-cache@$host" "$2"
}

# A machine's pointer and delta deleted, where it has any.
forget() {
	for o in "pending/$1" "pending/$1.sig" "pending/$1.objects"; do
		rclone deletefile "$objects/$o" 2>/dev/null || true
	done
}

# A pointer whose machine runs its path is done with, and so is every object no pending delta names.
sweep() {
	local m pointer path
	for m in $(jq -r '.machines | keys[]' "$given"); do
		pointer=$(rclone cat "$objects/pending/$m" 2>/dev/null) || continue
		path=$(jq -r .path <<<"$pointer")
		if [ "$(ask "$m" current </dev/null || true)" = "$path" ]; then
			forget "$m"
			echo "machine-cache: $m runs $path, its pointer and delta deleted"
		fi
	done
	# Listed before the deltas are read, as a run writes its delta before its objects, so what a
	# fallback builder uploads meanwhile is kept; a builder's own runs never overlap.
	rclone lsf -R --files-only "$objects" | sort >"$work/listed"
	{
		echo nix-cache-info
		sed -n '/^pending\//p' "$work/listed"
		sed -n '/^pending\/.*\.objects$/p' "$work/listed" | while read -r o; do
			rclone cat "$objects/$o"
		done
	} | sort -u >"$work/kept"
	comm -23 "$work/listed" "$work/kept" >"$work/unkept"
	[ ! -s "$work/unkept" ] || rclone delete --files-from-raw "$work/unkept" "$objects"
	echo "machine-cache: $(wc -l <"$work/unkept") objects no pending pointer needs deleted"
}

sweep

mkdir -p /var/lib/machine/cache-systems
system=$(nix build --refresh --print-out-paths "${on[@]}" \
	--out-link "/var/lib/machine/cache-systems/$machine" \
	"$flake#nixosConfigurations.\"$machine\".config.system.build.toplevel")
# A machine running the system already keeps no pointer, as an older one would take it back.
if [ "$(ask "$machine" current </dev/null)" = "$system" ]; then
	forget "$machine"
	echo "machine-cache: $machine runs $system already; its pointer and delta deleted, nothing uploaded"
	exit 0
fi
nix path-info -r "${on[@]}" "$system" >"$work/closure"
ask "$machine" lacks <"$work/closure" >"$work/lacking"
# The machine's answer taken only where it names paths of the closure.
if grep -qvxFf "$work/closure" "$work/lacking"; then
	echo "machine-cache: $machine named paths outside its system's closure; nothing uploaded" >&2
	exit 1
fi

# The whole closure signed into a directory first, as Nix uploads no path whose references the
# store it writes lacks, then the objects of the paths the machine lacks taken from it alone.
nix copy "${from[@]}" --to "file://$work/staging?compression=zstd&secret-key=$(field .signingKey)" "$system"
while read -r p; do
	h=${p#/nix/store/}
	h=${h%%-*}
	echo "$h.narinfo"
	sed -n 's/^URL: //p' "$work/staging/$h.narinfo"
done <"$work/lacking" | sort -u >"$work/delta"

rclone lsf -R --files-only --format sp --separator ' ' "$objects" >"$work/sized"
used=$(awk '{ s += $1 } END { print s + 0 }' "$work/sized")
added=0
while read -r o; do
	grep -qxF "$o" <(cut -d ' ' -f 2- "$work/sized") || added=$((added + $(stat -c %s "$work/staging/$o")))
done <"$work/delta"
if ((used + added > cap)); then
	echo "machine-cache: the bucket holds $used bytes and $machine's delta $added more, past the cap of $cap; nothing uploaded" >&2
	exit 1
fi

# The old pointer gone first and the new one written last, so a pointer always has its objects.
for o in "pending/$machine" "pending/$machine.sig"; do
	rclone deletefile "$objects/$o" 2>/dev/null || true
done
rclone copyto "$work/delta" "$objects/pending/$machine.objects"
rclone copy --no-traverse --files-from-raw <(echo nix-cache-info && cat "$work/delta") \
	"$work/staging" "$objects"
at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg machine "$machine" --arg path "$system" --arg at "$at" \
	'{ machine: $machine, path: $path, at: $at }' >"$work/pointer"
ssh-keygen -Y sign -f "$(field .pointerKey)" -n machine-cache "$work/pointer"
rclone copyto "$work/pointer.sig" "$objects/pending/$machine.sig"
rclone copyto "$work/pointer" "$objects/pending/$machine"
echo "machine-cache: $machine's system $system, $(wc -l <"$work/closure") paths, $(wc -l <"$work/lacking") lacking, $(wc -l <"$work/delta") objects of $added new bytes uploaded, pending/$machine signed at $at"
