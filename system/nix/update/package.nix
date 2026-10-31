# The update path's three programs, built from the repository's Cargo workspace, RFC cbtjl; the
# tests start a Nix daemon, so they run in verify and in check and not in the build.
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
    cargoExtraArgs = "--locked -p machine-update";
    # harmonia's crates share one git checkout, fetched as a derivation a cache can serve.
    outputHashes."git+https://github.com/nix-community/harmonia?tag=harmonia-v3.3.0#1424ae3f4e4218782f6ecd2714f989a7a1798bbc" =
      "sha256-Q25ZdQ47e3SR/pUf/l9TrmEXvdW9eGSd9Vk3njnXbms=";
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
