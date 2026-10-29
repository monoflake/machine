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
  given = pkgs.writeText "machine-cache.json" (
    builtins.toJSON {
      inherit (cfg) bucket;
      builders = map (b: {
        inherit (b) name;
        signers = pkgs.writeText "machine-cache-${if b.name == null then "legacy" else b.name}-signer" (
          ''builder namespaces="machine-cache" ${b.pointer}'' + "\n"
        );
      }) cfg.fetch.builders;
      signers = pkgs.writeText "machine-cache-legacy-signers" (
        lib.concatMapStrings (
          b: ''builder namespaces="machine-cache" ${b.pointer}'' + "\n"
        ) cfg.fetch.builders
      );
      machine = config.machine.name;
      # Upstream as the machine takes it otherwise, for every path the bucket does not carry.
      substituters = lib.concatStringsSep " " config.nix.settings.substituters;
      trusted = lib.concatStringsSep " " (
        map (b: b.nix) cfg.fetch.builders ++ config.nix.settings.trusted-public-keys
      );
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
    text =
      builtins.readFile ./endpoint.sh + builtins.readFile ./protocol.sh + builtins.readFile ./fetch.sh;
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
    systemd.timers.machine-cache-fetch = lib.mkIf (cfg.builder.self == null) {
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
