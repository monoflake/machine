# The driver's package as the template takes it from root's manifest.lock on both Linux systems,
# fetching nothing; driver-test.sh runs it on this checkout and on a copy holding driver.lock.
{
  root ? ../..,
  fixture ? false,
}:
let
  flake = builtins.getFlake ("path:" + toString root);
  inherit (flake.inputs.nixpkgs) lib;
  locked = builtins.fromTOML (builtins.readFile (flake.outPath + "/system/containers/manifest.lock"));
  pin = locked.driver-machine or null;
  override = "/var/lib/driver-machine/dev/driver-machine";
  template =
    system: extra:
    (lib.nixosSystem {
      modules = [
        flake.nixosModules.machine
        (flake.outPath + "/system/template/configuration.nix")
        {
          nixpkgs.hostPlatform = system;
          machine.driver.enable = true;
        }
        extra
      ];
    }).config;
  started = config: unit: config.systemd.services.${unit}.serviceConfig.ExecStart;
  check =
    system:
    let
      config = template system { };
      overridden = template system { machine.driver.override = override; };
      inherit (config.machine.driver) package;
      architecture = lib.removeSuffix "-linux" system;
      executable = builtins.unsafeDiscardStringContext "${package}/bin/driver-machine";
      tests = {
        overrideWins =
          overridden.machine.driver.package == null
          && lib.hasInfix override (started overridden "driver-machine")
          && lib.hasInfix override (started overridden "driver-machine-entry");
      }
      // (
        if pin == null then
          { absent = !fixture && package == null; }
        else
          {
            named = package.pname == "driver-machine" && package.version == pin.version;
            released =
              package.src.urls == [
                "https://github.com/${pin.source}/releases/download/${pin.release}/driver-machine-${pin.version}-linux-${architecture}.tar.gz"
              ];
            locked = package.src.urls == [ pin.${system}.url ];
            hashed = package.src.outputHash == pin.${system}.sha256 && package.src.outputHashMode == "flat";
            served =
              lib.hasInfix executable (started config "driver-machine")
              && lib.hasInfix executable (started config "driver-machine-entry");
            validAssertions = lib.all (a: a.assertion) config.assertions;
          }
      );
    in
    assert lib.assertMsg (lib.all (v: v) (builtins.attrValues tests))
      "Driver evaluation on ${system} failed for ${
        lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: v: !v) tests))
      }";
    {
      inherit tests;
      url = if pin == null then null else lib.head package.src.urls;
    };
in
lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] check
