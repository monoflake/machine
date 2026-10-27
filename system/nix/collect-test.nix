# Evaluate the store's collection schedule and free space settings on both Linux architectures.
{
  root ? ../..,
}:
let
  flake = builtins.getFlake ("path:" + toString root);
  inherit (flake.inputs.nixpkgs) lib;
  machine =
    system:
    (lib.nixosSystem {
      modules = [
        flake.nixosModules.machine
        (flake.outPath + "/system/template/configuration.nix")
        { nixpkgs.hostPlatform = system; }
      ];
    }).config;
  check =
    system:
    let
      cfg = machine system;
      timer = cfg.systemd.timers.nix-gc.timerConfig;
    in
    {
      collects = cfg.nix.gc.automatic && cfg.systemd.timers.nix-gc.wantedBy == [ "timers.target" ];
      everySixHours = timer.OnCalendar == [ "*-*-* 00/6:00:00" ];
      persistent = timer.Persistent;
      minFree = (cfg.nix.settings.min-free or null) == 1073741824;
      maxFree = (cfg.nix.settings.max-free or null) == 2147483648;
      lastThreeKept = lib.hasSuffix "--delete-generations +3" cfg.systemd.services.nix-gc.preStart;
      newSystem = cfg.systemd.paths.nix-gc.pathConfig.PathChanged == "/nix/var/nix/profiles";
    };
  tests = lib.concatMapAttrs (
    system: result: lib.mapAttrs' (name: lib.nameValuePair "${system}-${name}") result
  ) (lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] check);
in
assert lib.assertMsg (lib.all (v: v) (builtins.attrValues tests))
  "Collection evaluation failed for ${
    lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: v: !v) tests))
  }";
tests
