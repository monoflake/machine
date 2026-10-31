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
      inherit (cfg)
        bucket
        credentialsFile
        endpointFile
        driverBuilds
        ;
      machine = config.machine.name;
      signers = pkgs.writeText "system-pointer-signers" (
        ''ci namespaces="system-pointer" ${cfg.pointerPublicKey}'' + "\n"
      );
      driverChannel = config.machine.driver.enable && config.machine.driver.channel;
      architecture = pkgs.stdenv.hostPlatform.system;
      driverSigners = pkgs.writeText "driver-pointer-signers" (
        ''ci namespaces="driver-pointer" ${cfg.pointerPublicKey}''
        + "\n"
        + lib.optionalString (cfg.testSigner != null) (
          ''mac namespaces="driver-pointer" ${cfg.testSigner}'' + "\n"
        )
      );
      trusted = lib.concatStringsSep " " config.nix.settings.trusted-public-keys;
    }
  );
  package = pkgs.callPackage ./package.nix { };
  # The service's own check by hand, run over ssh, which realises nothing and writes no state.
  check = pkgs.writeShellScriptBin "machine-update-check" ''
    export MACHINE_UPDATE_CONFIG=${given}
    export AWS_SHARED_CREDENTIALS_FILE=${toString cfg.credentialsFile}
    instance=''${1:-system}
    case $instance in system | driver) ;; *) echo 'update: unsupported instance' >&2; exit 1 ;; esac
    export STATE_DIRECTORY=/var/lib/machine-update/$instance
    exec ${lib.getExe' package "machine-update-fetch"} "$instance" --dry-run
  '';
  rollback = pkgs.linkFarm "machine-driver-rollback" [
    {
      name = "bin/machine-driver-rollback";
      path = lib.getExe' package "machine-driver-rollback";
    }
  ];
in
{
  imports = [ ./nudge.nix ];

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
      environment.systemPackages = [
        check
      ]
      ++ lib.optional (config.machine.driver.enable && config.machine.driver.channel) rollback;
      systemd = {
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
            ExecStart = "${lib.getExe' package "machine-update-fetch"} %i";
            StateDirectory = "machine-update/%i";
            StateDirectoryMode = "0700";
            UMask = "0077";
          };
        };
        timers."update-now@driver" =
          lib.mkIf (config.machine.driver.enable && config.machine.driver.channel)
            {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = "*-*-* ${cfg.at}:00 UTC";
                Persistent = true;
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
