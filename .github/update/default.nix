# The commit message for the flake at new, its inputs moved from where the flake at old locks them.
# Each closure is what closure.jq makes of that flake's systems, before and after.
{
  old,
  new,
  closures,
}:
let
  inherit ((builtins.getFlake new).inputs.nixpkgs) lib;
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
  held =
    flake:
    lib.mapAttrs (_: version: [ version ]) (
      lib.foldl' (set: system: import ./held.nix flake system // set) { } systems
    );
  locked = flake: (lib.importJSON "${builtins.getFlake flake}/flake.lock").nodes;
  moved = lib.filter (name: name != "root" && (locked old).${name} or null != (locked new).${name}) (
    builtins.attrNames (locked new)
  );
  closure = lib.mapAttrs (_: lib.importJSON) closures;

  # A version as a release names it, with no archive, patch or output after it.
  plain =
    version:
    builtins.match "[0-9][^-]*(-unstable-[0-9]{4}-[0-9]{2}-[0-9]{2})?" version != null
    && builtins.match ".*[.](tar|tgz|tbz|zip|patch|diff|gem|whl)([.].*)?" version == null;
  # What only builds or tests a package, which a machine never runs.
  tooling =
    name:
    lib.any (pattern: builtins.match pattern name != null) [
      "python3[0-9.]*-.*"
      ".*-tests?"
      ".*-test-support"
      ".*bootstrap.*"
      "nixos-system-.*"
    ];
  versions =
    names:
    let
      parsed = map builtins.parseDrvName names;
      kept = builtins.filter (drv: plain drv.version && !tooling drv.name) parsed;
    in
    lib.mapAttrs (_: drvs: lib.sort lib.versionOlder (lib.unique (map (drv: drv.version) drvs))) (
      lib.groupBy (drv: drv.name) kept
    );

  seen = lib.genAttrs closure.old.paths (_: true);
  rebuilt = builtins.length (builtins.filter (path: !(seen ? ${path})) closure.new.paths);

  # A patch named for a CVE is counted once for each package it is new in.
  cve = patch: {
    cve = builtins.head (builtins.match ".*(CVE-[0-9]{4}-[0-9]+).*" patch.patch);
    package = (builtins.parseDrvName patch.package).name;
  };
  key = patch: "${patch.cve} ${patch.package}";
  before = lib.genAttrs (map (patch: key (cve patch)) closure.old.patched) (_: true);
  patched = lib.unique (
    builtins.filter (patch: !(before ? ${key patch})) (map cve closure.new.patched)
  );
in
import ./message.nix {
  inherit
    lib
    moved
    rebuilt
    patched
    ;
  held = {
    old = held old;
    new = held new;
  };
  beneath = {
    old = versions closure.old.names;
    new = versions closure.new.names;
  };
}
