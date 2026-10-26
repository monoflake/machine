# A builder's run for one machine, docs/cache.md. The bucket swept, the machine's system built, the
# paths it lacks uploaded under the cap and the pointer to the system signed last.
given=$MACHINE_CACHE_CONFIG
field() { jq -r "$1" "$given"; }

# The machine's wrapper is reached through the tailnet where one runs.
ask() {
	local host proxy=()
	host=$(jq -r --arg m "$1" '.machines[$m].host' "$given")
	[ "$(field .tailnet)" != true ] || proxy=(-o "ProxyCommand=tailscale nc %h %p")
	ssh -i "$(field .accessKey)" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=30 \
		-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/var/lib/machine/cache-known-hosts \
		"${proxy[@]}" "machine-cache@$host" "$2"
}

# Objects are listed before deltas so concurrent uploads remain protected.
protect_path() {
	local path=$1 hash info url ref
	local -a refs
	hash=${path##*/}; hash=${hash%%-*}
	grep -qxF "$hash.narinfo" "$work/kept" && return 0
	echo "$hash.narinfo" >>"$work/kept"
	info=$(rclone cat "$objects/$hash.narinfo" 2>/dev/null) || return 0
	url=$(sed -n 's/^URL: //p' <<<"$info")
	[ -z "$url" ] || echo "$url" >>"$work/kept"
	read -r -a refs <<<"$(sed -n 's/^References: //p' <<<"$info")"
	for ref in "${refs[@]}"; do protect_path "$ref"; done
}
forget() {
	local suffix
	for suffix in "" .sig .objects; do
		rclone deletefile "$objects/$1$suffix" 2>/dev/null || true
	done
}
sweep() {
	local m b pointer at newest newest_path applied o modified now running
	now=$(date -u +%s)
	rclone lsjson -R --files-only "$objects" >"$work/listed.json"
	jq -r '.[].Path' "$work/listed.json" | sort >"$work/listed"
	: >"$work/kept"
	echo nix-cache-info >>"$work/kept"
	for m in $(jq -r '.machines | keys[]' "$given"); do
		if grep -qxF "pending/$m" "$work/listed"; then
			rclone cat "$objects/pending/$m" >"$work/candidate" 2>/dev/null || true
			if cache_pointer "$work/candidate" "$m" "$now" 2>/dev/null; then
				pointer=$(jq -r .path "$work/candidate")
				running=""
				if ! running=$(ask "$m" current </dev/null); then
					echo "machine-cache: could not ask $m what it runs, its legacy pointer kept"
				elif [ "$running" = "$pointer" ]; then
					forget "pending/$m"
				fi
				if [ "${running:-}" != "$pointer" ]; then protect_path "$pointer"; fi
			fi
		fi
		newest=""; newest_path=""
		: >"$work/pointers"
		while read -r b; do
			pointer=$(rclone cat "$objects/$b" 2>/dev/null) || continue
			[ -n "$pointer" ] || continue
			printf '%s' "$pointer" >"$work/candidate"
			if ! cache_pointer "$work/candidate" "$m" "$now" 2>/dev/null; then
				echo "machine-cache: $m's pointer names no valid path or time, passed over"
				continue
			fi
			at=$(jq -r .at <<<"$pointer")
			printf '%s %s\n' "$at" "$b" >>"$work/pointers"
			if [[ $at > $newest ]]; then newest=$at; newest_path=$(jq -r .path <<<"$pointer"); fi
		done < <(grep -E "^pending/$m/[^.]+$" "$work/listed" || true)
		[ -n "$newest" ] || continue
		protect_path "$newest_path"
		if ! applied=$(ask "$m" applied </dev/null | jq -er '.at | strings' 2>/dev/null); then
			echo "machine-cache: could not ask $m what it applied, its pointers kept"
			continue
		fi
		while read -r at b; do
			if [[ $b == "pending/$m/$builder" && $at < $newest && $at < $applied ]]; then
				for o in "$b" "$b.sig" "$b.objects"; do
					rclone deletefile "$objects/$o" 2>/dev/null || true
				done
			fi
		done <"$work/pointers"
	done
	while read -r o; do
		rclone cat "$objects/$o" >>"$work/kept" 2>/dev/null || true
	done < <(rclone lsf -R --files-only "$objects" | grep '\.objects$' || true)
	sort -u "$work/kept" >"$work/kept.sorted"
	while IFS=$'\t' read -r o modified; do
		[[ $o != pending/* ]] || continue
		grep -qxF "$o" "$work/kept.sorted" && continue
		modified=$(cache_epoch "$modified" 2>/dev/null) || continue
		((now - modified >= 7200)) || continue
		rclone deletefile "$objects/$o" 2>/dev/null || true
	done < <(jq -r '.[] | [.Path, .ModTime] | @tsv' "$work/listed.json")
}

publish() {
	local at
	at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	jq -n --arg machine "$machine" --arg path "$system" --arg at "$at" \
		'{ machine: $machine, path: $path, at: $at }' >"$work/pointer"
	ssh-keygen -Y sign -f "$(field .pointerKey)" -n machine-cache "$work/pointer"
	rclone deletefile "$objects/$prefix" 2>/dev/null || true
	rclone copyto "$work/pointer.sig" "$objects/$prefix.sig"
	rclone copyto "$work/pointer" "$objects/$prefix"
}

# Timer timestamps keep a delayed start attached to the slot that triggered it.
slot_minute() {
	local builders index now minute offset b mine=-1 k=0 trigger candidate latest=-1
	local triggered=false exact=false start end
	builders=$(jq -c --arg m "$machine" '.machines[$m].builders // {}' "$given")
	slot_day=$(date -u +%F)
	window=$(cache_epoch "$slot_day 00:00:00Z")
	deadline=0
	last=false
	[ "$builders" != '{}' ] || return 0
	now=$(date -u +%s)
	if [ "$manual" = false ]; then
		trigger=$now
		if [[ ${TRIGGER_TIMER_REALTIME_USEC:-} =~ ^[0-9]+$ ]]; then
			trigger=$((TRIGGER_TIMER_REALTIME_USEC / 1000000))
			triggered=true
		fi
		minute=$(date -u -d "@$trigger" +%H:%M)
		index=$(jq -r --arg m "$machine" --arg at "$minute" '.machines[$m].slots | index($at) // empty' "$given")
		if [ -n "$index" ]; then
			exact=true
			trigger=$((trigger - trigger % 60))
		else
			while read -r minute; do
				candidate=$(cache_epoch "$(date -u -d "@$trigger" +%F) $minute:00Z")
				((candidate <= trigger)) || candidate=$((candidate - 86400))
				if ((candidate > latest)); then latest=$candidate; index=$k; fi
				k=$((k + 1))
			done < <(jq -r --arg m "$machine" '.machines[$m].slots[]' "$given")
			trigger=$latest
		fi
		[ -n "$index" ] || { echo "machine-cache: slot missed: started late" >&2; return 1; }
		offset=$(jq -r --arg m "$machine" --argjson k "$index" '.machines[$m].slotDays[$k] // 0' "$given")
		slot_day=$(date -u -d "@$((trigger - offset * 86400))" +%F)
	else index=-1
	fi
	k=0
	while read -r b; do
		[ "$b" != "$builder" ] || mine=$k
		k=$((k + 1))
	done < <(cache_order "$machine" "$slot_day" "$builders")
	[ "$mine" != -1 ] || return 1
	if [ "$manual" = false ]; then
		minute=$(jq -r --arg m "$machine" --argjson k "$mine" '.machines[$m].slots[$k]' "$given")
		offset=$(jq -r --arg m "$machine" --argjson k "$mine" '.machines[$m].slotDays[$k] // 0' "$given")
		start=$(cache_epoch "$slot_day $minute:00Z")
		start=$((start + offset * 86400))
		end=$((start + gap * 60))
		if [ "$mine" != "$index" ]; then
			if [ "$triggered" = true ] || [ "$exact" = true ] || ((now < end)); then return 2; fi
		fi
		if ((now >= end)); then echo "machine-cache: slot missed: started late" >&2; return 1; fi
		deadline=$((now - now % 60 + 60))
		((deadline <= end)) || deadline=$end
	fi
	[ "$mine" != "$((k - 1))" ] || last=true
	minute=$(jq -r --arg m "$machine" '.machines[$m].slots[0]' "$given")
	offset=$(jq -r --arg m "$machine" '.machines[$m].slotDays[0] // 0' "$given")
	window=$(cache_epoch "$slot_day $minute:00Z")
	window=$((window + offset * 86400))
}
slot() {
	local builders now at b claim epoch
	builders=$(jq -c --arg m "$machine" '.machines[$m].builders // {}' "$given")
	[ "$builders" != '{}' ] || return 0
	while read -r b; do
		now=$(date -u +%s)
		if rclone cat "$objects/pending/$machine/$b" >"$work/answer" 2>/dev/null \
			&& cache_pointer "$work/answer" "$machine" "$now" 2>/dev/null; then
			at=$(cache_epoch "$(jq -r .at "$work/answer")")
			if ((at >= window)) && { [ "$manual" = false ] || \
				[ "$(jq -r .path "$work/answer")" = "$system" ]; }; then return 2; fi
		fi
	done < <(jq -r 'keys[]' <<<"$builders")
	while read -r b; do
		claim=$(rclone cat "$objects/pending/$machine/$b.claim" 2>/dev/null) || continue
		[ -n "$claim" ] || continue
		now=$(date -u +%s)
		epoch=$(cache_epoch "$claim" 2>/dev/null) || continue
		# A minute of margin lets the next slot proceed after a slightly late claim.
		if ((now - epoch < gap * 60 - 60 && epoch <= now)); then
			[ "$last" = false ] || { echo "machine-cache: last slot blocked by a claim" >&2; exit 1; }
			return 2
		fi
	done < <(jq -r 'keys[]' <<<"$builders")
	date -u +%Y-%m-%dT%H:%M:%SZ >"$work/claim"
	rclone copyto "$work/claim" "$objects/$prefix.claim"
}

# Cache shell tests source these functions without running a build.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

machine=$1
builder=$(field .builder)
prefix="pending/$machine/$builder"
manual=false
self=false
[ "${2:-}" != --now ] || manual=true
[ "${2:-}" != --self ] || self=true
gap=$(jq -r --arg m "$machine" '.machines[$m].gap // 20' "$given")
flake=$(jq -r --arg m "$machine" '.machines[$m].flake // empty' "$given")
[ -n "$flake" ] || {
	echo "machine-cache: $machine is not built here" >&2
	exit 1
}
system=""
if [ "$self" = false ]; then
	status=0
	slot_minute || status=$?
	[ "$status" != 2 ] || exit 0
	[ "$status" = 0 ] || exit "$status"
else deadline=0
fi
state=${MACHINE_CACHE_STATE:-/var/lib/machine}
mkdir -p "$state"
lock=${MACHINE_CACHE_LOCK:-/run/lock/machine-cache}
exec 9>>"$lock"
wait=1800
if ((deadline > 0)); then wait=$((deadline - $(date -u +%s))); fi
holder=$(cat "$lock.owner" 2>/dev/null || echo unknown)
if ((wait <= 0)) || ! flock -w "$wait" 9; then
	holder=$(cat "$lock.owner" 2>/dev/null || echo "$holder")
	echo "machine-cache: slot missed: lock held by $holder" >&2
	exit 1
fi
if ((deadline > 0 && $(date -u +%s) >= deadline)); then
	echo "machine-cache: slot missed: lock held by $holder" >&2
	exit 1
fi
printf '%s\n' "$machine" >"$lock.owner"
bucket=$(field .bucket)
cap=$(field .cap)
store=$(field '.store // empty')
on=()
[ -z "$store" ] || on=(--store "$store")
from=()
[ -z "$store" ] || from=(--from "$store")
work=$(mktemp -d "${TMPDIR:-/var/tmp}/machine-cache.XXXXXX")
fetch_failed=false
finish() {
	local status=$?
	if [ "$fetch_failed" = true ]; then
		cat "$work/fetch-failures" >&2
		status=1
	fi
	rm -f "$lock.owner"
	rm -rf "$work"
	exit "$status"
}
trap finish EXIT

# The bucket as rclone reaches it, or the directory standing in for it.
export RCLONE_CONFIG=/dev/null
if [[ $bucket == /* ]]; then
	mkdir -p "$bucket"
	objects=$bucket
	cache_store="file://$bucket"
else
	export RCLONE_S3_PROVIDER=Cloudflare RCLONE_S3_ENV_AUTH=true RCLONE_S3_NO_CHECK_BUCKET=true
	endpoint=$(endpoint_host "$bucket") || exit 1
	export RCLONE_S3_ENDPOINT="https://$endpoint"
	objects=":s3:$bucket"
	cache_store="s3://$bucket?endpoint=$endpoint&scheme=https&region=auto"
fi
if [[ $bucket == /* && $self == false ]] && [ -f "$bucket/pending/$machine" ] \
	&& [ "$(jq -c --arg m "$machine" '.machines[$m].builders // {}' "$given")" != '{}' ]; then
	echo "machine-cache: legacy pointer pending/$machine must be moved aside before tiered builds" >&2
	exit 1
fi
if [ "$self" = false ] && [ "$(jq -c --arg m "$machine" '.machines[$m].builders // {}' "$given")" = '{}' ]; then
	prefix="pending/$machine"
fi

if [ "$self" = true ] && [ "$(field .self)" = cache ] && [ "$(field .fetch)" != null ]; then
	if MACHINE_CACHE_CONFIG=$(field .fetch.config) MACHINE_CACHE_FALLBACK=true \
		"$(field .fetch.command)" 2>"$work/fetch-failures"; then
		cat "$work/fetch-failures" >&2
		exit 0
	else status=$?
	fi
	case $status in
	2) ;;
	3)
		fetch_failed=true
		[ -s "$work/fetch-failures" ] || echo "machine-cache: self fetch failed with status $status" >"$work/fetch-failures"
		;;
	*)
		cat "$work/fetch-failures" >&2
		exit "$status"
		;;
	esac
fi
target="$flake#nixosConfigurations.\"$machine\".config.system.build.toplevel"
if [ "$self" = false ]; then
	if [ "$manual" = true ]; then
		system=$(nix eval --refresh --raw "${on[@]}" "$target.outPath")
	fi
	status=0
	slot || status=$?
	[ "$status" != 2 ] || exit 0
	[ "$status" = 0 ] || exit "$status"
fi
sweep
mkdir -p "$state/cache-systems"
system=$(nix build --refresh --print-out-paths "${on[@]}" \
	--out-link "$state/cache-systems/$machine" "$target")
if [ "$self" = false ]; then
	running=$(ask "$machine" current </dev/null) || exit 1
	if [ "$running" = "$system" ]; then
		if [ "$prefix" = "pending/$machine" ]; then
			forget "$prefix"
		else
			rclone deletefile "$objects/$prefix.objects" 2>/dev/null || true
			publish
		fi
		exit 0
	fi
fi
nix path-info -r "${on[@]}" "$system" >"$work/closure"
if [ "$self" = true ]; then
	nix-env -p /nix/var/nix/profiles/system --set "$system"
	"$system/bin/switch-to-configuration" switch
	cache_record "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$system" "$state/cache-applied"
	: >"$work/lacking"
	while read -r p; do
		nix path-info --store "$cache_store" "$p" >/dev/null 2>&1 || echo "$p" >>"$work/lacking"
	done <"$work/closure"
else
	ask "$machine" lacks <"$work/closure" >"$work/lacking"
	if grep -qvxFf "$work/closure" "$work/lacking"; then
		echo "machine-cache: $machine named paths outside its closure" >&2
		exit 1
	fi
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

if [ "$self" = false ]; then
	for o in "$prefix" "$prefix.sig"; do
		rclone deletefile "$objects/$o" 2>/dev/null || true
	done
	rclone copyto "$work/delta" "$objects/$prefix.objects"
fi
rclone copy --no-traverse --files-from-raw <(echo nix-cache-info && cat "$work/delta") \
	"$work/staging" "$objects"
[ "$self" = true ] || publish
