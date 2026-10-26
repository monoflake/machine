#!/usr/bin/env bash
# run.sh's sweep over a directory standing in for the bucket, rclone and ssh faked, each pointer it
# forgets and each it keeps.
set -o errexit -o nounset -o pipefail

tmp=$(mktemp -d)
trap '[ $? = 0 ] || cat "$tmp/stderr" >&2 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/bucket/pending" "$tmp/bucket/nar" "$tmp/runs"
: >"$tmp/runs/asked"
export SWEEP_RUNS=$tmp/runs PATH=$tmp/bin:$PATH

# Rclone over a directory, a missing object read as nothing with success, as R2's was on 2026-10-26.
cat >"$tmp/bin/rclone" <<'EOF'
#!/usr/bin/env bash
case $1 in
cat) cat "$2" 2>/dev/null || true ;;
deletefile) rm -f "$2" ;;
lsf) (cd "${!#}" && find . -type f | sed 's|^\./||') ;;
delete) while read -r o; do rm -f "${!#}/$o"; done <"$3" ;;
*) exit 1 ;;
esac
EOF
# Each host's wrapper answering current as its file in runs says, and a host with none refusing.
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
host=${@: -2:1}
host=${host#machine-cache@}
echo "$host" >>"$SWEEP_RUNS/asked"
[ "${!#}" = current ] && [ -f "$SWEEP_RUNS/$host" ] || {
	echo "machine-cache@$host: Permission denied (publickey)." >&2
	exit 255
}
cat "$SWEEP_RUNS/$host"
EOF
chmod +x "$tmp/bin/rclone" "$tmp/bin/ssh"

store=/nix/store
declare -A pointed=(
	[upgraded]=$store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-upgraded-26.05
	[unasked]=$store/1123456789abcdfghijklmnpqrsvwxyz-nixos-system-unasked-26.05
	[behind]=$store/2123456789abcdfghijklmnpqrsvwxyz-nixos-system-behind-26.05
)
behind_runs=$store/3123456789abcdfghijklmnpqrsvwxyz-nixos-system-behind-26.05

# Absent has no pointer, blank, garbled and numbered each one naming no path, and the other three
# each a pointer and delta.
jq -n '{ accessKey: "/var/lib/secrets/access-key", tailnet: false,
	machines: ([ "absent", "blank", "garbled", "numbered", "upgraded", "unasked", "behind" ]
		| map({ key: ., value: { host: . } }) | from_entries) }' >"$tmp/given.json"
b=$tmp/bucket
echo "StoreDir: $store" >"$b/nix-cache-info"
echo '{ "machine": "blank" }' >"$b/pending/blank"
echo '{ "machine": "garbled", "path": ' >"$b/pending/garbled"
echo '{ "machine": "numbered", "path": 7 }' >"$b/pending/numbered"
for m in upgraded unasked behind; do
	jq -n --arg m "$m" --arg p "${pointed[$m]}" '{ machine: $m, path: $p, at: "2026-10-26T14:30:00Z" }' \
		>"$b/pending/$m"
	echo signature >"$b/pending/$m.sig"
	printf '%s.narinfo\nnar/%s.nar.zst\n' "$m" "$m" >"$b/pending/$m.objects"
	touch "$b/$m.narinfo" "$b/nar/$m.nar.zst"
done
touch "$b/stray.narinfo"
echo "${pointed[upgraded]}" >"$tmp/runs/upgraded"
echo "$behind_runs" >"$tmp/runs/behind"
: >"$tmp/runs/blank"

MACHINE_CACHE_CONFIG=$tmp/given.json
# shellcheck source=system/nix/cache/run.sh
. "$(dirname "$0")/run.sh"
objects=$b
work=$tmp/work
mkdir -p "$work"
sweep >"$tmp/said" 2>"$tmp/stderr"

failed=0
# The count as BSD's wc pads it too, squeezed.
said=$(tr -s ' ' <"$tmp/said")
want="machine-cache: blank's pointer names no path, passed over
machine-cache: garbled's pointer names no path, passed over
machine-cache: numbered's pointer names no path, passed over
machine-cache: could not ask unasked what it runs, its pointer kept
machine-cache: upgraded runs ${pointed[upgraded]}, its pointer and delta deleted
machine-cache: 3 objects no pending pointer needs deleted"
if [ "$said" != "$want" ]; then
	printf 'sweep: said\n%s\nnot\n%s\n' "$said" "$want" >&2
	failed=1
fi
asked=$(sort "$tmp/runs/asked" | tr '\n' ' ')
if [ "$asked" != "behind unasked upgraded " ]; then
	echo "sweep: asked $asked, not behind, unasked and upgraded alone" >&2
	failed=1
fi
left=$(cd "$b" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')
want="behind.narinfo nar/behind.nar.zst nar/unasked.nar.zst nix-cache-info pending/behind pending/behind.objects pending/behind.sig pending/blank pending/garbled pending/numbered pending/unasked pending/unasked.objects pending/unasked.sig unasked.narinfo "
if [ "$left" != "$want" ]; then
	printf 'sweep: left %s\nnot %s\n' "$left" "$want" >&2
	failed=1
fi

[ "$failed" = 0 ] && echo "sweep: upgraded forgotten; absent, blank, garbled, numbered, unasked and behind kept; 3 objects deleted"
exit "$failed"
