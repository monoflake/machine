# Each builder runs at every slot of each consumer, docs/cache.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.machine.cache;
  # What a run reads, the bucket, upstream, its keys and every machine built here.
  given = pkgs.writeText "machine-cache.json" (
    builtins.toJSON {
      inherit (cfg) bucket;
      builder = config.networking.hostName;
      self = cfg.builder.self;
      fetch =
        if cfg.fetch.builders == [ ] then
          null
        else
          {
            command = config.systemd.services.machine-cache-fetch.serviceConfig.ExecStart;
            config = config.systemd.services.machine-cache-fetch.environment.MACHINE_CACHE_CONFIG;
          };
      inherit (cfg.builder)
        cap
        data
        store
        upstream
        signingKey
        pointerKey
        accessKey
        ;
      machines =
        cfg.builds
        // lib.optionalAttrs (cfg.builder.self != null) {
          ${config.networking.hostName} = {
            flake = config.machine.upgrade.flake;
            host = config.networking.hostName;
            builders = { };
            slots = [ ];
            gap = 20;
          };
        };
      tailnet = config.services.tailscale.enable;
    }
  );
  run = pkgs.writeShellApplication {
    name = "machine-cache-run";
    # Git as NixOS's own upgrade holds it, which Nix runs to fetch a git+ssh flake.
    # See tests/build/build-test.sh.
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.curl
      pkgs.findutils
      pkgs.gawk
      pkgs.gitMinimal
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.openssh
      pkgs.rclone
      pkgs.util-linux
    ]
    ++ lib.optional config.services.tailscale.enable config.services.tailscale.package;
    text =
      builtins.readFile ./endpoint.sh + builtins.readFile ./protocol.sh + builtins.readFile ./run.sh;
  };
  service = name: immediate: {
    description = "The system of ${name}, built and handed through the cache";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # Never stopped or restarted by a switch while a run is in flight.
    restartIfChanged = false;
    unitConfig.X-StopOnRemoval = false;
    environment.MACHINE_CACHE_CONFIG = given;
    serviceConfig = {
      Type = "oneshot";
      # A hung build fails visibly while later slots can deliver another answer.
      TimeoutStartSec = "50min";
      ExecStart = "${lib.getExe run} ${name}${lib.optionalString immediate " --now"}";
      EnvironmentFile = lib.mkIf (cfg.credentials != null) cfg.credentials;
      StateDirectory = "machine";
    };
  };

in
{
  options.machine.cache.builder.upstream = lib.mkOption {
    type = lib.types.str;
    default = "https://cache.nixos.org";
    description = "Binary cache a run asks for the closure of what it built, uploading only the paths it lacks; every mirror the fleet takes paths from copies it.";
  };

  config = lib.mkIf (cfg.enable && (cfg.builds != { } || cfg.builder.self != null)) {
    environment.systemPackages = [ run ];
    system.autoUpgrade.enable = lib.mkIf (cfg.builder.self != null) (lib.mkForce false);

    systemd = {
      services =
        lib.mapAttrs' (name: _: lib.nameValuePair "machine-cache-${name}" (service name false)) cfg.builds
        // lib.mapAttrs' (
          name: _: lib.nameValuePair "machine-cache-now@${name}" (service name true)
        ) cfg.builds
        // lib.optionalAttrs (cfg.builder.self != null) {
          machine-cache-self = {
            description = "The builder upgrades its own system";
            wants = [ "network-online.target" ];
            after = [ "network-online.target" ];
            restartIfChanged = false;
            unitConfig.X-StopOnRemoval = false;
            environment.MACHINE_CACHE_CONFIG = given;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${lib.getExe run} ${config.networking.hostName} --self";
              EnvironmentFile = lib.mkIf (cfg.credentials != null) cfg.credentials;
              StateDirectory = "machine";
            };
          };
        };

      timers =
        lib.mapAttrs' (
          name: m:
          lib.nameValuePair "machine-cache-${name}" {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              # A run missed while the builder was off is skipped, never caught up.
              AccuracySec = "1s";
              OnCalendar = map (at: "*-*-* ${at}:00 UTC") (if m.slots == [ ] then [ m.at ] else m.slots);
            };
          }
        ) (lib.filterAttrs (_: m: m.at != null || m.slots != [ ]) cfg.builds)
        // lib.optionalAttrs (cfg.builder.self != null) {
          machine-cache-self = {
            wantedBy = [ "timers.target" ];
            timerConfig.OnCalendar = "*-*-* ${config.machine.upgrade.at}:00 UTC";
            timerConfig.Persistent = true;
          };
        };
    };
  };
}
