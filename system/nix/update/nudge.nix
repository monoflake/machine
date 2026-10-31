{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.machine.nudge;
  package = config.machine.update.package;
  command = lib.getExe' package "machine-update-nudge";
  # A shell package NixOS accepts, which runs the forced command whatever it is given.
  shell =
    pkgs.writeShellScriptBin "nudge-shell" ''
      exec ${command}
    ''
    // {
      shellPath = "/bin/nudge-shell";
    };
in
{
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.key != null -> cfg.expiry != null;
          message = "machine.nudge.key requires machine.nudge.expiry.";
        }
        {
          assertion = cfg.key != null -> config.machine.update.enable;
          message = "machine.nudge.key requires machine.update.enable.";
        }
        {
          assertion = cfg.expiry != null -> cfg.key != null;
          message = "machine.nudge.expiry requires machine.nudge.key.";
        }
      ];
    }
    (lib.mkIf (cfg.key != null) {
      users.groups.nudge = { };
      users.users.nudge = {
        isSystemUser = true;
        group = "nudge";
        inherit shell;
        hashedPassword = "!";
        openssh.authorizedKeys = {
          keys = lib.mkForce [
            ''restrict,command="${command}",expiry-time="${cfg.expiry}" ${cfg.key}''
          ];
          keyFiles = lib.mkForce [ ];
        };
      };
      security.polkit = {
        enable = true;
        extraConfig = ''
          polkit.addRule(function(action, subject) {
            if (subject.user === "nudge" &&
                action.id === "org.freedesktop.systemd1.manage-units" &&
                action.lookup("verb") === "start" &&
                (action.lookup("unit") === "update-now@system.service" ||
                 action.lookup("unit") === "update-now@driver.service")) {
              return polkit.Result.YES;
            }
          });
        '';
      };
    })
  ];
}
