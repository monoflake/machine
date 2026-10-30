{
  flake,
  pointerKey,
  nixKey,
}:
let
  inherit (flake.inputs.nixpkgs) lib;
  options = {
    bucket = "fixture";
    at = "13:00";
    pointerPublicKey = pointerKey;
    nixPublicKey = nixKey;
    credentialsFile = "/run/secrets/systems-credentials";
    endpointFile = "/run/secrets/systems-endpoint";
  };
  configured =
    system: update: extra:
    (lib.nixosSystem {
      modules = [
        flake.nixosModules.machine
        ../../../template/configuration.nix
        {
          nixpkgs.hostPlatform = system;
          machine.update = {
            enable = true;
          }
          // update;
          nixpkgs.overlays = [
            (_: previous: {
              writeTextFile =
                args:
                if args.name == "nix.conf" then
                  builtins.toFile args.name (builtins.unsafeDiscardStringContext args.text)
                else
                  previous.writeTextFile args;
              writeText =
                name: text:
                if name == "system-update-credentials.conf" || name == "machine-update.json" then
                  builtins.toFile name (builtins.unsafeDiscardStringContext text)
                else
                  previous.writeText name text;
            })
          ];
        }
        extra
      ];
    }).config;
  rejected = c: lib.any (a: !a.assertion && lib.hasPrefix "machine.update." a.message) c.assertions;
  check =
    system:
    let
      c = configured system options { machine.upgrade.flake = "fixture"; };
      disabled = configured system { enable = false; } { };
      conflict = configured system options {
        machine.cache.enable = true;
        machine.cache.bucket = "/tmp/fixture";
      };
      unit = c.systemd.services."update-now@";
      daemon = c.systemd.services.nix-daemon;
      timer = c.systemd.timers."update-now@system".timerConfig;
      nixConf = builtins.readFile c.environment.etc."nix/nix.conf".source;
      missing = map (name: configured system (builtins.removeAttrs options [ name ]) { }) (
        builtins.attrNames options
      );
    in
    assert lib.all rejected missing;
    assert rejected conflict;
    assert !rejected c;
    assert !rejected disabled;
    assert !(disabled.systemd.services ? "update-now@");
    assert !c.system.autoUpgrade.enable;
    assert c.nix.settings.substituters == disabled.nix.settings.substituters;
    assert builtins.elem nixKey c.nix.settings.trusted-public-keys;
    assert lib.all (
      key: builtins.elem key c.nix.settings.trusted-public-keys
    ) disabled.nix.settings.trusted-public-keys;
    assert !lib.hasInfix options.credentialsFile nixConf;
    assert !lib.hasInfix options.endpointFile nixConf;
    assert !lib.hasInfix "endpoint=" nixConf;
    assert daemon.environment.AWS_SHARED_CREDENTIALS_FILE == options.credentialsFile;
    assert !(daemon.environment ? AWS_ACCESS_KEY_ID);
    assert !(daemon.environment ? AWS_SECRET_ACCESS_KEY);
    assert unit.environment.AWS_SHARED_CREDENTIALS_FILE == options.credentialsFile;
    assert !(unit.environment ? AWS_ACCESS_KEY_ID);
    assert !(unit.environment ? AWS_SECRET_ACCESS_KEY);
    assert unit.restartIfChanged == false;
    assert unit.unitConfig.X-StopOnRemoval == false;
    assert unit.serviceConfig.Type == "oneshot";
    assert unit.serviceConfig.StateDirectory == "machine-update/%i";
    assert unit.serviceConfig.StateDirectoryMode == "0700";
    assert lib.hasSuffix " %i" unit.serviceConfig.ExecStart;
    assert timer.OnCalendar == "*-*-* 13:00:00 UTC";
    assert timer.Persistent;
    {
      passed = true;
    };
in
lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] check
