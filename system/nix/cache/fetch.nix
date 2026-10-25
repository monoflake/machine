# A fetched machine, its system taken from its builder through the bucket each day in place of
# evaluating its own flake, and the user its builder asks two questions as, docs/cache.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.machine.cache;
  # Each builder's pointer key, under the one name a pointer is verified as.
  signers = pkgs.writeText "machine-cache-signers" (
    lib.concatMapStrings (
      b: ''builder namespaces="machine-cache" ${b.pointer}'' + "\n"
    ) cfg.fetch.builders
  );
  given = pkgs.writeText "machine-cache.json" (
    builtins.toJSON {
      inherit (cfg) bucket;
      inherit signers;
      machine = config.networking.hostName;
      trusted = lib.concatMapStringsSep " " (b: b.nix) cfg.fetch.builders;
    }
  );
  fetch = pkgs.writeShellApplication {
    name = "machine-cache-fetch";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.openssh
    ];
    text = builtins.readFile ./fetch.sh;
  };
  answer = pkgs.writeShellApplication {
    name = "machine-cache-answer";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
    ];
    text = builtins.readFile ./answer.sh;
  };
  restricted = ''restrict,from="${lib.concatStringsSep "," cfg.fetch.from}",command="${lib.getExe answer}"'';
in
{
  config = lib.mkIf (cfg.enable && cfg.fetch.builders != [ ]) {
    systemd.services.machine-cache-fetch = {
      description = "The system its builder built, fetched through the cache and switched to";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # Never stopped or restarted by the switch it makes, as NixOS's own upgrade is not.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      environment.MACHINE_CACHE_CONFIG = given;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe fetch;
        EnvironmentFile = lib.mkIf (cfg.credentials != null) cfg.credentials;
        StateDirectory = "machine";
      };
    };
    systemd.timers.machine-cache-fetch = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* ${config.machine.upgrade.at}:00 UTC";
        # A day missed while the machine was off is caught up when it comes back.
        Persistent = true;
      };
    };

    # Each builder's access key runs the wrapper and nothing else, from the tailnet alone.
    users = {
      users.machine-cache = {
        isSystemUser = true;
        group = "machine-cache";
        useDefaultShell = true;
        openssh.authorizedKeys.keys = map (b: "${restricted} ${b.access}") cfg.fetch.builders;
      };
      groups.machine-cache = { };
    };
  };
}
