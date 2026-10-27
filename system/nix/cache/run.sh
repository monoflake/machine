# A builder's run for one machine, docs/cache.md. The machine's system built, the paths of its
# closure upstream lacks uploaded while the bucket is under the cap and the pointer signed last.

# Every exit prints the run's outcome as its last line, a contract another repository reads.
finish() {
	trap '' TERM
	local status=$1
	set +e
	if [ "$fetch_failed" = true ]; then
		cat "$work/fetch-failures" >&2
		status=1
	fi
	if [ "$status" != 0 ] && [[ $outcome != missed && $outcome != claimed ]]; then
		outcome=failed
	fi
	[ -z "$work" ] || rm -rf "$work" || status=$?
	if [ "$lock_owned" = true ] && [ -n "$gc_store" ]; then
		rm -rf -- "${TMPDIR:?}"/* "$TMPDIR"/.[!.]* "$TMPDIR"/..?* || status=$?
		nix store gc --store "$gc_store" --option keep-derivations false \
			--option keep-outputs false || status=$?
	fi
	[ "$lock_owned" = false ] || rm -f "$lock.owner" || status=$?
	if [ "$self" = true ]; then
		printf 'machine-cache outcome=%s consumer=%s self=%s\n' "$outcome" "$machine" "$self_outcome"
	else
		printf 'machine-cache outcome=%s consumer=%s\n' "$outcome" "$machine"
	fi
	exit "$status"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	machine=${1:-}
	self=false
	[ "${2:-}" != --self ] || self=true
	outcome=failed
	self_outcome=failed
	fetch_failed=false
	lock_owned=false
	gc_store=""
	work=""
	trap 'finish "$?"' EXIT
	trap 'exit 143' TERM
fi

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

# The old pointer and its signature withdrawn, so neither outlives the other.
retract() {
	local o
	for o in "$1" "$1.sig"; do
		rclone deletefile "$objects/$o" 2>/dev/null || true
	done
}

# The closure's paths upstream lacks, the run's own set, docs/cache.md. An upstream not reached or
# not answering for exactly the closure fails the run before anything is published.
own_set() {
	if ! nix path-info --store "$upstream" --option narinfo-cache-meta-ttl 0 --json --json-format 1 \
		--stdin <"$work/closure" >"$work/upstream.json" 2>"$work/upstream-errors"; then
		cat "$work/upstream-errors" >&2
		echo "machine-cache: upstream $upstream could not be asked for the closure; nothing published" >&2
		return 1
	fi
	if ! jq -e --rawfile closure "$work/closure" \
		'type == "object" and (keys == ($closure | split("\n") | map(select(length > 0)) | unique))' \
		"$work/upstream.json" >/dev/null 2>&1; then
		echo "machine-cache: upstream $upstream answered for other paths than the closure; nothing published" >&2
		return 1
	fi
	jq -r 'to_entries[] | select(.value == null) | .key' "$work/upstream.json" >"$work/asked" || return 1
	: >"$work/lacking"
	[ -s "$work/asked" ] || return 0
	# Nix reads a 403 as a missing path, so each path it calls missing is asked again and only a 404
	# counts as lacking, docs/cache.md. The store's parameters are no part of the narinfo's URL.
	local base=${upstream%%[?#]*}
	if ! cut -c 12-43 "$work/asked" | xargs -P 16 -I '{}' \
		curl -s -L --max-redirs 5 --max-time 20 --retry 2 --retry-connrefused -o /dev/null \
		-w '%{http_code} {}\n' "${base%/}/{}.narinfo" >"$work/codes"; then
		echo "machine-cache: upstream $upstream could not be asked again for a path; nothing published" >&2
		return 1
	fi
	if [ "$(wc -l <"$work/codes")" != "$(wc -l <"$work/asked")" ]; then
		echo "machine-cache: upstream $upstream left a path unanswered; nothing published" >&2
		return 1
	fi
	if awk '$1 != 200 && $1 != 404 { print; found = 1 } END { exit !found }' "$work/codes" \
		>"$work/refused"; then
		echo "machine-cache: upstream $upstream answered $(head -n 1 "$work/refused").narinfo; nothing published" >&2
		return 1
	fi
	while read -r code hash; do
		[ "$code" != 404 ] || grep "^/nix/store/$hash-" "$work/asked" >>"$work/lacking"
	done <"$work/codes"
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
		if [ -z "$index" ]; then
			outcome=missed
			echo "machine-cache: slot missed: started late" >&2
			return 1
		fi
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
		if ((now >= end)); then
			outcome=missed
			echo "machine-cache: slot missed: started late" >&2
			return 1
		fi
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
				[ "$(jq -r .path "$work/answer")" = "$system" ]; }; then outcome=answered; return 2; fi
		fi
	done < <(jq -r 'keys[]' <<<"$builders")
	while read -r b; do
		claim=$(rclone cat "$objects/pending/$machine/$b.claim" 2>/dev/null) || continue
		[ -n "$claim" ] || continue
		now=$(date -u +%s)
		epoch=$(cache_epoch "$claim" 2>/dev/null) || continue
		# A minute of margin lets the next slot proceed after a slightly late claim.
		if ((now - epoch < gap * 60 - 60 && epoch <= now)); then
			outcome=claimed
			[ "$last" = false ] || { echo "machine-cache: last slot blocked by a claim" >&2; exit 1; }
			return 2
		fi
	done < <(jq -r 'keys[]' <<<"$builders")
	date -u +%Y-%m-%dT%H:%M:%SZ >"$work/claim"
	rclone copyto "$work/claim" "$objects/$prefix.claim"
}

# Cache shell tests source these functions without running a build.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

builder=$(field .builder)
prefix="pending/$machine/$builder"
manual=false
[ "${2:-}" != --now ] || manual=true
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
	[ "$status" != 2 ] || { outcome=skipped; exit 0; }
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
	outcome=missed
	echo "machine-cache: slot missed: lock held by $holder" >&2
	exit 1
fi
if ((deadline > 0 && $(date -u +%s) >= deadline)); then
	outcome=missed
	echo "machine-cache: slot missed: lock held by $holder" >&2
	exit 1
fi
lock_owned=true
printf '%s\n' "$machine" >"$lock.owner"
bucket=$(field .bucket)
cap=$(field .cap)
upstream=$(field .upstream)
store=$(field '.store // empty')
gc_store=""
on=()
evaluate=()
from=()
if [ "$(field '.data // false')" = true ]; then
	gc_store=$store
	evaluate=(--eval-store "$store")
fi
if [ -n "$store" ]; then
	on=(--store "$store")
	from=(--from "$store")
fi
work=$(mktemp -d "${TMPDIR:-/var/tmp}/machine-cache.XXXXXX")

# The bucket as rclone reaches it, or the directory standing in for it.
export RCLONE_CONFIG=/dev/null
if [[ $bucket == /* ]]; then
	mkdir -p "$bucket"
	objects=$bucket
else
	export RCLONE_S3_PROVIDER=Cloudflare RCLONE_S3_ENV_AUTH=true RCLONE_S3_NO_CHECK_BUCKET=true
	endpoint=$(endpoint_host "$bucket") || exit 1
	export RCLONE_S3_ENDPOINT="https://$endpoint"
	objects=":s3:$bucket"
fi
if [[ $bucket == /* && $self == false ]] && [ -f "$bucket/pending/$machine" ] \
	&& [ "$(jq -c --arg m "$machine" '.machines[$m].builders // {}' "$given")" != '{}' ]; then
	echo "machine-cache: legacy pointer pending/$machine must be moved aside before tiered builds" >&2
	exit 1
fi
if [ "$self" = false ] && [ "$(jq -c --arg m "$machine" '.machines[$m].builders // {}' "$given")" = '{}' ]; then
	prefix="pending/$machine"
fi
# A run for another machine refreshes nix-cache-info first, so expiry never takes it, docs/cache.md.
if [ "$self" = false ]; then
	printf 'StoreDir: /nix/store\n' >"$work/nix-cache-info"
	rclone copyto --no-check-dest "$work/nix-cache-info" "$objects/nix-cache-info"
fi

if [ "$self" = true ] && [ "$(field .self)" = cache ] && [ "$(field .fetch)" != null ]; then
	if MACHINE_CACHE_CONFIG=$(field .fetch.config) MACHINE_CACHE_FALLBACK=true \
		"$(field .fetch.command)" 2>"$work/fetch-failures"; then
		cat "$work/fetch-failures" >&2
		outcome=answered
		self_outcome=fetched
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
		system=$(nix eval --refresh --raw "${on[@]}" "${evaluate[@]}" "$target.outPath")
	fi
	status=0
	slot || status=$?
	[ "$status" != 2 ] || exit 0
	[ "$status" = 0 ] || exit "$status"
fi
mkdir -p "$state/cache-systems"
system=$(nix build --refresh --print-out-paths "${on[@]}" "${evaluate[@]}" \
	--out-link "$state/cache-systems/$machine" "$target")
if [ "$self" = false ]; then
	running=$(ask "$machine" current </dev/null) || exit 1
	if [ "$running" = "$system" ]; then
		if [ "$prefix" = "pending/$machine" ]; then retract "$prefix"; else publish; fi
		outcome=confirmed
		exit 0
	fi
fi
if [ "$self" = true ]; then
	# The chroot store alone substitutes the closure unsigned, held by temporary roots until the
	# profile roots it, docs/cache.md.
	activate=()
	[ -z "$gc_store" ] || activate=(--option substituters "$store&trusted=true")
	nix-env "${activate[@]}" -p /nix/var/nix/profiles/system --set "$system"
	"$system/bin/switch-to-configuration" switch
	self_outcome=built
	cache_record "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$system" "$state/cache-applied"
	# Nothing takes a builder's own system from the bucket, so its run publishes nothing.
	outcome=built
	exit 0
fi
nix path-info -r "${on[@]}" "$system" >"$work/closure"
own_set || exit 1
# The bucket's total measured once, the run's own set not added to it, docs/cache.md.
held=$(rclone size --fast-list --json "$objects" | jq -er '.bytes')
if ((held > cap)); then
	echo "machine-cache: the bucket holds $held bytes, past the cap of $cap; nothing uploaded" >&2
	exit 1
fi

# The whole closure signed into a directory first, as Nix uploads no path whose references the
# store it writes lacks, then the objects of the run's own set taken from it alone.
nix copy "${from[@]}" --to "file://$work/staging?compression=zstd&secret-key=$(field .signingKey)" "$system"
while read -r p; do
	h=${p#/nix/store/}
	h=${h%%-*}
	echo "$h.narinfo"
	sed -n 's/^URL: //p' "$work/staging/$h.narinfo"
done <"$work/lacking" | sort -u >"$work/upload"


grep -v '\.narinfo$' "$work/upload" >"$work/upload-data" || { status=$?; [ "$status" = 1 ] || exit "$status"; }
grep '\.narinfo$' "$work/upload" >"$work/upload-narinfo" || { status=$?; [ "$status" = 1 ] || exit "$status"; }
retract "$prefix"
# Every object uploaded again, unlisted and uncompared, so its age is this run's, docs/cache.md.
for pass in data narinfo; do
	if [ -s "$work/upload-$pass" ]; then
		rclone copy --no-check-dest --transfers 32 --files-from-raw "$work/upload-$pass" \
			"$work/staging" "$objects"
	fi
done
publish

outcome=built
