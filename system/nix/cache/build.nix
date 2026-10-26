# A builder's run for each machine it builds, an hour before that machine's upgrade, docs/cache.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.machine.cache;
  # What a run reads, the bucket, its keys and every machine built here, the sweep asking each.
  given = pkgs.writeText "machine-cache.json" (
    builtins.toJSON {
      inherit (cfg) bucket;
      inherit (cfg.builder)
        cap
        store
        signingKey
        pointerKey
        accessKey
        ;
      machines = lib.mapAttrs (_: m: { inherit (m) flake host; }) cfg.builds;
      tailnet = config.services.tailscale.enable;
    }
  );
  run = pkgs.writeShellApplication {
    name = "machine-cache-run";
    # Git as NixOS's own upgrade holds it, which Nix runs to fetch a git+ssh flake, build-test.sh.
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
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
    text = builtins.readFile ./endpoint.sh + builtins.readFile ./run.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.builds != { }) {
    environment.systemPackages = [ run ];

    systemd = {
      services = lib.mapAttrs' (
        name: _:
        lib.nameValuePair "machine-cache-${name}" {
          description = "The system of ${name}, built and handed through the cache";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          environment.MACHINE_CACHE_CONFIG = given;
          serviceConfig = {
            Type = "oneshot";
            # A run ends within the hour before its machine's upgrade, so a hung one fails visibly.
            TimeoutStartSec = "50min";
            ExecStart = "${lib.getExe run} ${name}";
            EnvironmentFile = lib.mkIf (cfg.credentials != null) cfg.credentials;
            StateDirectory = "machine";
          };
        }
      ) cfg.builds;

      timers = lib.mapAttrs' (
        name: m:
        lib.nameValuePair "machine-cache-${name}" {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            # A run missed while the builder was off is skipped, never caught up.
            OnCalendar = "*-*-* ${m.at}:00 UTC";
          };
        }
      ) (lib.filterAttrs (_: m: m.at != null) cfg.builds);
    };
  };
}
