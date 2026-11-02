#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
t=$(realpath "$(mktemp -d "$here/extlinux-test.XXXXXX")")
cleanup() {
	node -e 'require("node:fs").rmSync(process.argv[1], {recursive:true, force:true})' "$t"
}
trap cleanup EXIT
cp "$here/../../flake.nix" "$here/../../flake.lock" "$t/"
if [ -z "${EXTLINUX_TOOLS:-}" ]; then
	nix shell --inputs-from "path:$t" nixpkgs#bash nixpkgs#coreutils nixpkgs#gnused \
		nixpkgs#gnugrep -c env EXTLINUX_TOOLS=1 bash "$0"
	exit
fi
builder=$(nix build --impure --no-link --print-out-paths --builders "" --expr "
  let
    flake = builtins.getFlake \"path:$t\";
    pkgs = import flake.inputs.nixpkgs {};
  in import $here/extlinux-builder.nix { inherit pkgs; }")
mkdir -p "$t/bin" "$t/system/dtbs/vendor"
printf kernel >"$t/system/kernel"
printf initrd >"$t/system/initrd"
printf dtb >"$t/system/dtbs/vendor/board.dtb"
printf version >"$t/system/nixos-version"
printf console=ttyS0 >"$t/system/kernel-params"
export EXTLINUX_TEST=$t
export REAL_CP REAL_MV REAL_SYNC
REAL_CP=$(command -v cp)
REAL_MV=$(command -v mv)
REAL_SYNC=$(command -v sync)
cat >"$t/event" <<'EVENT'
set -e
root=$EXTLINUX_TEST
boot=$root/boot
conf=$boot/extlinux/extlinux.conf
step=$(cat "$root/step")
step=$((step + 1))
echo "$step" >"$root/step"
echo "$step $*" >>"$root/events"
if [ "$1" = sync ]; then
	if [ "$3" = "$boot" ]; then
		find "$boot/nixos" -type f ! -name '*.tmp.*' -exec cksum {} \; | sort >"$root/durable"
	elif [[ "$3" == "$boot/extlinux/extlinux.conf.tmp."* ]]; then
		"$REAL_CP" "$3" "$root/synced-conf"
	fi
fi
if [ "$1" = mv ] && [ "${@: -1}" = "$conf" ]; then
	cmp "$conf" "$root/synced-conf"
	touch "$root/published"
fi
if [ ! -f "$root/published" ]; then
	cmp "$conf" "$root/old-conf"
else
	while read -r directive path rest; do
		case "$directive" in
			LINUX|INITRD|FDT|FDTDIR)
				resolved=$(realpath "$boot/extlinux/$path")
				find "$resolved" -type f -exec cksum {} \; | while read -r checksum; do
					grep -Fx "$checksum" "$root/durable" >/dev/null
				done
				;;
		esac
	done <"$conf"
fi
[ "$step" != "$FAIL_AFTER" ] || exit 71
EVENT
for tool in cp mv sync; do
	cat >"$t/bin/$tool" <<'WRAPPER'
#!/usr/bin/env bash
set -e
name=${0##*/}
case "$name" in
	cp) "$REAL_CP" "$@" ;;
	mv) "$REAL_MV" "$@" ;;
	sync) "$REAL_SYNC" "$@" ;;
esac
PATH=${PATH#*:} source "$EXTLINUX_TEST/event" "$name" "$@"
WRAPPER
	chmod +x "$t/bin/$tool"
done
tools=$t/bin:$(dirname "$REAL_CP"):$(dirname "$(command -v bash)")
tools=$tools:$(dirname "$(command -v sed)"):$(dirname "$(command -v grep)"):/usr/bin:/bin
sed "s|^export PATH=.*|export PATH=/empty:$tools|" "$builder" >"$t/builder"
checks=0
for mode in directory named disabled; do
	args=()
	case "$mode" in
	named) args=(-n vendor/board.dtb) ;;
	disabled) args=(-r) ;;
	esac
	for cut in 0 1 2 3 4 5 6 7 8 9 10 11 12; do
		node -e 'require("node:fs").rmSync(process.argv[1], {recursive:true, force:true})' "$t/boot"
		mkdir -p "$t/boot/extlinux" "$t/boot/nixos"
		printf 'old configuration\n' >"$t/old-conf"
		cp "$t/old-conf" "$t/boot/extlinux/extlinux.conf"
		: >"$t/durable"
		: >"$t/events"
		echo 0 >"$t/step"
		node -e 'for (const p of process.argv.slice(1)) require("node:fs").rmSync(p, {force:true})' \
			"$t/published" "$t/synced-conf"
		status=0
		FAIL_AFTER=$cut bash -e "$t/builder" -t 5 -c "$t/system" -d "$t/boot" \
			"${args[@]}" >"$t/output" 2>&1 || status=$?
		if [ "$cut" = 0 ]; then
			if [ "$status" != 0 ]; then
				cat "$t/output"
				exit 1
			fi
			[ "$(cat "$t/step")" = 12 ]
			[ "$(tail -1 "$t/events")" = "12 sync -f $t/boot/extlinux" ]
		else
			if [ "$status" != 71 ]; then
				cat "$t/output"
				exit 1
			fi
			[ "$(cat "$t/step")" = "$cut" ]
		fi
		checks=$((checks + 1))
	done
done
echo "extlinux: $checks builder runs passed across three device tree modes" \
	"and every copy, sync and rename cut"
