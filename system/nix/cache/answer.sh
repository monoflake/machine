# The cache channel reports the current system and missing paths, docs/cache.md.
case ${SSH_ORIGINAL_COMMAND:-} in
current)
	readlink /run/current-system
	;;
# No run of the new design asks it, kept for a builder not yet moved, RFC ttcli.
lacks)
	given=$(head -c 16000000)
	if printf '%s\n' "$given" | grep -qvxE '/nix/store/[0-9a-z]{32}-[0-9A-Za-z+._?=-]+'; then
		echo "machine-cache: only store paths, one a line" >&2
		exit 1
	fi
	printf '%s\n' "$given" | xargs -r nix-store --check-validity --print-invalid
	;;
*)
	echo "machine-cache: ask current or lacks" >&2
	exit 1
	;;
esac
