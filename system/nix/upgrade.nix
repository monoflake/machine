# A machine upgrading itself each day from its own flake, switched and never rebooted, RFC vr5lw.
{ config, lib, ... }:
let
  cfg = config.machine.upgrade;
in
{
  config = lib.mkIf (cfg.flake != null) {
    system.autoUpgrade = {
      enable = true;
      inherit (cfg) flake;
      dates = "*-*-* ${cfg.at}:00 UTC";
      # A day missed while the machine was off is caught up when it comes back.
      persistent = true;
      allowReboot = false;
    };

    # GitHub's host key, as GitHub publishes it, and the key a private flake there is read with.
    programs.ssh = {
      knownHosts."github.com".publicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
      extraConfig = lib.mkIf (cfg.keyFile != null) ''
        Host github.com
          IdentityFile ${cfg.keyFile}
          IdentitiesOnly yes
      '';
    };
  };
}
