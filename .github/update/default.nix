# The commit message for the flake at new, its inputs moved from where the flake at old locks them.
{ old, new }:
let
  inherit ((builtins.getFlake new).inputs.nixpkgs) lib;
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
  held = flake: lib.foldl' (set: system: import ./held.nix flake system // set) { } systems;
  locked = flake: (lib.importJSON "${builtins.getFlake flake}/flake.lock").nodes;
  moved = lib.filter (name: name != "root" && (locked old).${name} or null != (locked new).${name}) (
    builtins.attrNames (locked new)
  );
in
import ./message.nix {
  inherit lib moved;
  old = held old;
  new = held new;
}
