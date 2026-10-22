# The isolate runtimes' images, this machine's architecture's archive of each fetched by the address
# and SHA-256 manifest.lock locks, for the driver to import, RFC vr5lw.
{ lib, pkgs, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  pinned = lib.filterAttrs (_: lib.isAttrs) (builtins.fromTOML (builtins.readFile ./manifest.lock));
  archive =
    name: pin:
    pkgs.fetchurl {
      name = "${name}-${pin.version}.tar";
      inherit (pin.${system}) url sha256;
    };
in
{
  environment.etc = lib.mapAttrs' (
    name: pin: lib.nameValuePair "monoflake/images/${name}.tar" { source = archive name pin; }
  ) pinned;
}
