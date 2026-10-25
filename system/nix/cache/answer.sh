# What a builder's access key runs on a fetched machine, docs/cache.md. The current system's path,
# or which of the store paths given on stdin the machine lacks, writing nothing.
case ${SSH_ORIGINAL_COMMAND:-} in
current)
	readlink /run/current-system
	;;
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
