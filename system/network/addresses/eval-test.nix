# The discovery option adds only its service and timer when enabled.
{
  root ? ../../..,
  base ? null,
}:
let
  flake = builtins.getFlake ("path:" + toString root);
  inherit (flake.inputs.nixpkgs) lib;
  template =
    source: extra:
    (lib.nixosSystem {
      modules = [
        source.nixosModules.machine
        (source.outPath + "/system/template/configuration.nix")
        { nixpkgs.hostPlatform = "x86_64-linux"; }
        extra
      ];
    }).config;
  off = template flake { };
  without = template flake { disabledModules = [ ./default.nix ]; };
  on = template flake { machine.addresses.enable = true; };
  shared = template flake {
    machine.addresses.enable = true;
    machine.cache = {
      enable = true;
      bucket = "/var/empty/cache";
      builds.example = {
        flake = "/var/empty/flake";
        host = "192.0.2.10";
      };
      builder = lib.genAttrs [ "signingKey" "pointerKey" "accessKey" ] (_: "/var/empty/key");
      fetch = {
        from = [ "192.0.2.0/24" ];
        builders = [
          {
            pointer = "example";
            nix = "example";
            access = "example";
          }
        ];
      };
    };
  };
  service = on.systemd.services.machine-addresses;
  timer = on.systemd.timers.machine-addresses;
  tests = {
    defaultOff = !off.machine.addresses.enable;
    absentOff =
      !(off.systemd.services ? machine-addresses) && !(off.systemd.timers ? machine-addresses);
    unchangedOff = off.system.build.toplevel.drvPath == without.system.build.toplevel.drvPath;
    oneshot =
      service.serviceConfig.Type == "oneshot" && service.serviceConfig.TimeoutStartSec == "infinity";
    ordering =
      lib.elem "network-online.target" service.wants
      && lib.elem "network-online.target" service.after
      && lib.elem "tailscaled.service" service.after;
    state = service.serviceConfig.StateDirectory == "machine" && service.serviceConfig.UMask == "0077";
    sharedDirectoryMode = lib.all (
      unit:
      let
        directories = unit.serviceConfig.StateDirectory or [ ];
        names = if builtins.isList directories then directories else lib.splitString " " directories;
        usesMachine = lib.any (name: builtins.head (lib.splitString ":" name) == "machine") names;
      in
      usesMachine -> (unit.serviceConfig.StateDirectoryMode or "0755") == "0755"
    ) (builtins.attrValues shared.systemd.services);
    hourly =
      timer.timerConfig.OnBootSec == "0"
      && timer.timerConfig.OnUnitActiveSec == "1h"
      && lib.elem "timers.target" timer.wantedBy;
  }
  // lib.optionalAttrs (base != null) {
    unchangedBase =
      off.system.build.toplevel.drvPath == (template (builtins.getFlake ("path:" + toString base)) { })
      .system.build.toplevel.drvPath;
  };
in
assert lib.assertMsg (lib.all (v: v) (builtins.attrValues tests))
  "Address evaluation failed for ${
    lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: v: !v) tests))
  }";
{
  inherit tests;
  drvPath = off.system.build.toplevel.drvPath;
  unit = on.systemd.units."machine-addresses.service".text;
  timer = on.systemd.units."machine-addresses.timer".text;
}
