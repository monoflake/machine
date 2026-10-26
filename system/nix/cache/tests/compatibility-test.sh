#!/usr/bin/env bash
# Legacy pointer reads match the recorded fixture without a sibling checkout.
set -o errexit -o nounset -o pipefail
cache_dir=$(cd "$(dirname "$0")" && pwd)
real_nix=$(command -v nix)
compare_base() {
	local base=${MACHINE_CACHE_BASE:-}
	if [ -z "$base" ]; then
		echo "skipped: no base given"
		return 0
	fi
	comparison=$(mktemp -d)
	mkdir "$comparison/base" "$comparison/lane"
	rsync -a --exclude=.jj --exclude=.git --exclude=node_modules "$base/" "$comparison/base/"
	rsync -a --exclude=.jj --exclude=.git --exclude=node_modules "$(dirname "$0")/../../../../" "$comparison/lane/"
	"$real_nix" eval --impure --json --expr "
	let
	  base = builtins.getFlake \"path:$comparison/base\";
	  lane = builtins.getFlake \"path:$comparison/lane\";
	  inherit (base.inputs.nixpkgs) lib;
	  paths = f: {
	    checks = lib.mapAttrs (_: lib.mapAttrs (_: d: d.drvPath)) f.checks;
	    formatter = lib.mapAttrs (_: d: d.drvPath) f.formatter;
	    templates = lib.mapAttrs (_: v: {
	      inherit (v) description;
	      files = builtins.readDir v.path;
	      flake = builtins.readFile (v.path + \"/flake.nix\");
	      configuration = builtins.readFile (v.path + \"/configuration.nix\");
	    }) f.templates;
	  };
	  old = paths base;
	  new = paths lane;
	in assert old == new; {
	  equal = true;
	  inherit (new) checks formatter;
	  outputs = builtins.attrNames base.outputs;
	}
	"
}
. "$cache_dir/test-support.sh"
setup_test
trap 'rm -rf "$t"; [ -z "${comparison:-}" ] || rm -rf "$comparison"' EXIT
mkdir "$t/flake"
rsync -a --exclude=.jj --exclude=.git --exclude=node_modules "$cache_dir/../../../../" "$t/flake/"
"$real_nix" eval --impure --json --expr "
let flake = builtins.getFlake \"path:$t/flake\";
in import $cache_dir/eval/compatibility-test.nix {
  inherit flake;
  keys = map builtins.readFile [ $t/a1.pub $t/a2.pub ];
}
" >"$t/fixtures"
real_cp=$(command -v cp)
export CACHE_TEST_CP=$real_cp
cat >"$t/bin/cp" <<'SH'
#!/usr/bin/env bash
case $1 in
"$TEST_ROOT/bucket/pending/"*) echo "${1#"$TEST_ROOT/bucket/"}" >>"$TEST_ROOT/read-paths" ;;
esac
exec "$CACHE_TEST_CP" "$@"
SH
chmod +x "$t/bin/cp"
while read -r expected; do
	m=$(jq -r .machine <<<"$expected")
	drv=$(jq -r --arg m "$m" '.[$m].derivation' "$t/fixtures")
	"$real_nix" derivation show --recursive "$drv" >"$t/derivations"
	file=$(jq -r --arg m "$m" '.[$m].file' "$t/fixtures")
	jq -r --arg f "$file" '(.derivations // .)[] | select(((.outputs.out.path // "") | split("/") | last) == ($f | split("/") | last)) | .env.text' "$t/derivations" >"$t/config-source"
	while read -r signer; do
		jq -r --arg f "$signer" '(.derivations // .)[] | select(((.outputs.out.path // "") | split("/") | last) == ($f | split("/") | last)) | .env.text' "$t/derivations" >"$t/$(basename "$signer")"
	done < <(jq -r '.signers, .builders[].signers' "$t/config-source" | sort -u)
	jq --arg t "$t" '.bucket=($t+"/bucket") | .signers=($t+"/"+(.signers|split("/")|last)) | .builders |= map(.signers=($t+"/"+(.signers|split("/")|last)))' "$t/config-source" >"$t/enabled.json"
	jq -e --argjson expected "$(jq .builders <<<"$expected")" '
		if .builders[0].name == null then (.builders | length) == 1 and ($expected | length) == 1
		else [.builders[].name] == $expected end' "$t/enabled.json" >/dev/null
	[ ! -d "$t/bucket/pending/$m" ] || rmdir "$t/bucket/pending/$m"
	jq .pointer <<<"$expected" >"$t/bucket/pending/$m"
	ssh-keygen -q -Y sign -f "$t/$(jq -r .signedBy <<<"$expected")" \
		-n machine-cache "$t/bucket/pending/$m"
	export MACHINE_CACHE_CONFIG=$t/enabled.json
	rm -f "$MACHINE_CACHE_APPLIED"
	: >"$t/read-paths"
	fetch_test
	jq -r '.pointerReads[]' <<<"$expected" >"$t/expected-paths"
	cmp "$t/read-paths" "$t/expected-paths"
	jq -e --argjson expected "$(jq .pointer <<<"$expected")" '. == $expected' \
		"$t/bucket/pending/$m" >/dev/null
done < <(jq -c '.consumers[]' "$cache_dir/fixtures/legacy-layout.json")

rm -f "$t/bucket/pending/c1" "$t/bucket/pending/c1.sig"
jq '.machines.c1.builders={} | .machines.c1.slots=[]' "$t/build.json" >"$t/legacy-build.json"
mv "$t/legacy-build.json" "$t/build.json"
echo "$ref" >"$t/hosts/c1/current"
run_test --now
while read -r object; do [ -f "$t/bucket/$object" ]; done \
	< <(jq -r '.consumers[] | select(.machine == "c1") | .objects[]' "$cache_dir/fixtures/legacy-layout.json")
echo "$path" >"$t/hosts/c1/current"
run_test --now
[ ! -f "$t/bucket/pending/c1" ] && [ ! -f "$t/bucket/pending/c1.sig" ]
[ ! -f "$t/bucket/pending/c1.objects" ]
echo "compatibility: enabled one and two builder consumers match the recorded legacy layout"
compare_base
