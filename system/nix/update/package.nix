# The update path's three programs, built from the repository's Cargo workspace, RFC cbtjl; the
# tests start a Nix daemon, so they run in verify on the Mac and not in the build.
{ lib, craneLib }:
let
  root = ../../..;
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/Cargo.toml")
      (root + "/Cargo.lock")
      ./Cargo.toml
      ./src
    ];
  };
  commonArgs = {
    pname = "machine-update";
    version = "0.1.0";
    inherit src;
    cargoExtraArgs = "-p machine-update";
    doCheck = false;
  };
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (
  commonArgs
  // {
    inherit cargoArtifacts;
    meta = {
      description = "A machine's signed updates, its system and its driver taken from the bucket's pointers";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  }
)
