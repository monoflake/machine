{
  flake,
  pointerKey,
  nixKey,
}:
let
  inherit (flake.inputs.nixpkgs) lib;
  configured =
    system: driver: update:
    (lib.nixosSystem {
      modules = [
        flake.nixosModules.machine
        ../../../template/configuration.nix
        {
          nixpkgs.hostPlatform = system;
          nixpkgs.overlays = [
            (_: previous: {
              writeText =
                name: text:
                if name == "machine-update.json" then
                  builtins.toFile name (builtins.unsafeDiscardStringContext text)
                else
                  previous.writeText name text;
            })
          ];
          machine.driver = {
            enable = true;
            channel = true;
          }
          // driver;
          machine.update = {
            enable = true;
            bucket = "fixture";
            at = "13:00";
            pointerPublicKey = pointerKey;
            nixPublicKey = nixKey;
            credentialsFile = "/run/secrets/systems-credentials";
            endpointFile = "/run/secrets/systems-endpoint";
          }
          // update;
        }
      ];
    }).config;
  rejected = c: lib.any (a: !a.assertion && lib.hasPrefix "machine.driver" a.message) c.assertions;
  check =
    system:
    let
      c = configured system { } { };
      package = c.nix.package;
      pkgs = import flake.inputs.nixpkgs { inherit system; };
      updatePackage = pkgs.callPackage (flake.outPath + "/system/nix/update/package.nix") { };
      rollback = pkgs.linkFarm "machine-driver-rollback" [
        {
          name = "bin/machine-driver-rollback";
          path = lib.getExe' updatePackage "machine-driver-rollback";
        }
      ];
      frozen = configured system { channel = false; } { };
      overridden = configured system {
        channel = false;
        override = "/tmp/driver-machine";
      } { };
      unit = c.systemd.services."update-now@";
      given =
        config:
        builtins.fromJSON (
          builtins.readFile config.systemd.services."update-now@".environment.MACHINE_UPDATE_CONFIG
        );
      builds = configured system { } { driverBuilds = true; };
      signer = configured system { } { testSigner = pointerKey; };
      timer = c.systemd.timers."update-now@driver";
      binary = "/var/lib/driver/current/driver-machine";
    in
    assert !rejected c;
    assert !c.machine.update.driverBuilds;
    assert !(given c).driverBuilds;
    assert (given builds).driverBuilds;
    assert builds.machine.update.testSigner == null;
    assert !(given signer).driverBuilds;
    assert (given c).driverChannel;
    assert lib.hasSuffix ".drv" c.system.build.toplevel.drvPath;
    assert rejected (configured system { inherit package; } { });
    assert rejected (configured system { override = "/tmp/driver-machine"; } { });
    assert rejected (configured system { } { enable = false; });
    assert rejected (
      configured system {
        channel = false;
        inherit package;
        override = "/tmp/driver-machine";
      } { }
    );
    assert !rejected frozen;
    assert !rejected overridden;
    assert c.machine.driver.package == null;
    assert frozen.machine.driver.package != null;
    assert overridden.machine.driver.package == null;
    assert !(frozen.systemd.timers ? "update-now@driver");
    assert lib.all
      (
        name:
        lib.hasPrefix binary (lib.removePrefix "'" c.systemd.services.${name}.serviceConfig.ExecStart)
        && c.systemd.services.${name}.unitConfig.ConditionPathExists == binary
      )
      [
        "driver-machine"
        "driver-machine-entry"
      ];
    assert c.systemd.services.driver-machine-entry.serviceConfig.DynamicUser;
    assert c.systemd.services.driver-machine-entry.serviceConfig.ProtectSystem == "strict";
    assert builtins.elem "d /var/lib/driver 0755 root root -" c.systemd.tmpfiles.rules;
    assert unit.serviceConfig.StateDirectory == "machine-update/%i";
    assert unit.serviceConfig.StateDirectoryMode == "0700";
    assert timer.timerConfig.OnCalendar == "*-*-* 13:00:00 UTC";
    assert timer.timerConfig.Persistent;
    assert builtins.elem "timers.target" timer.wantedBy;
    assert unit.serviceConfig.ExecStart == "${lib.getExe' updatePackage "machine-update-fetch"} %i";
    assert builtins.elem rollback c.environment.systemPackages;
    assert !(builtins.elem updatePackage c.environment.systemPackages);
    assert !lib.any (p: p.name == "machine-driver-rollback") frozen.environment.systemPackages;
    assert !lib.any (p: p.name == "machine-driver-rollback") overridden.environment.systemPackages;
    {
      passed = true;
    };
in
lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] check
