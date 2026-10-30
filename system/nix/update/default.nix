{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.machine.update;
  given = pkgs.writeText "machine-update.json" (
    builtins.toJSON {
      inherit (cfg) bucket credentialsFile endpointFile;
      machine = config.machine.name;
      signers = pkgs.writeText "system-pointer-signers" (
        ''ci namespaces="system-pointer" ${cfg.pointerPublicKey}'' + "\n"
      );
      trusted = lib.concatStringsSep " " config.nix.settings.trusted-public-keys;
    }
  );
  fetch = pkgs.writeShellApplication {
    name = "machine-update-fetch";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.curl
      pkgs.gawk
      pkgs.jq
      pkgs.openssh
    ];
    text = builtins.readFile ./protocol.sh + builtins.readFile ./fetch.sh;
  };
  # The service's own check by hand, run over ssh, which realises nothing and writes no state.
  check = pkgs.writeShellScriptBin "machine-update-check" ''
    export MACHINE_UPDATE_CONFIG=${given}
    export AWS_SHARED_CREDENTIALS_FILE=${toString cfg.credentialsFile}
    export STATE_DIRECTORY=/var/lib/machine-update/system
    exec ${lib.getExe fetch} system --dry-run
  '';
in
{
  config = lib.mkMerge [
    {
      assertions = lib.optionals cfg.enable (
        map
          (name: {
            assertion = cfg.${name} != null;
            message = "machine.update.${name} must be set when updates are enabled.";
          })
          [
            "bucket"
            "at"
            "pointerPublicKey"
            "nixPublicKey"
            "credentialsFile"
            "endpointFile"
          ]
        ++ [
          {
            assertion = !config.machine.cache.enable;
            message = "machine.update.enable refuses machine.cache.enable.";
          }
        ]
      );
    }
    (lib.mkIf cfg.enable {
      nix.settings.trusted-public-keys = lib.optional (cfg.nixPublicKey != null) cfg.nixPublicKey;
      system.autoUpgrade.enable = lib.mkForce false;
      environment.systemPackages = [ check ];
      systemd = {
        # A path alone, so a realise through the daemon reads the same root only file.
        services.nix-daemon.environment.AWS_SHARED_CREDENTIALS_FILE = cfg.credentialsFile;
        services."update-now@" = {
          description = "Take the signed update pointer for %i";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          # The switch must leave its own updater running.
          restartIfChanged = false;
          unitConfig.X-StopOnRemoval = false;
          environment = {
            MACHINE_UPDATE_CONFIG = given;
            AWS_SHARED_CREDENTIALS_FILE = cfg.credentialsFile;
          };
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe fetch} %i";
            StateDirectory = "machine-update/%i";
            StateDirectoryMode = "0700";
            UMask = "0077";
          };
        };
        timers."update-now@system" = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* ${cfg.at}:00 UTC";
            Persistent = true;
          };
        };
      };
    })
  ];
}
