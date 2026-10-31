# The update path's three programs, built from the repository's Cargo workspace, RFC cbtjl; the
# tests start a Nix daemon, so they run in verify on the Mac and not in the build.
{ lib, rustPlatform }:
let
  root = ../../..;
in
rustPlatform.buildRustPackage {
  pname = "machine-update";
  version = "0.1.0";
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/Cargo.toml")
      (root + "/Cargo.lock")
      ./Cargo.toml
      ./src
    ];
  };
  cargoLock = {
    lockFile = root + "/Cargo.lock";
    # harmonia's crates share one git checkout, so one of them names its hash.
    outputHashes."harmonia-protocol-3.3.0" = "sha256-Q25ZdQ47e3SR/pUf/l9TrmEXvdW9eGSd9Vk3njnXbms=";
  };
  cargoBuildFlags = [
    "-p"
    "machine-update"
  ];
  doCheck = false;
  meta = {
    description = "A machine's signed updates, its system and its driver taken from the bucket's pointers";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
