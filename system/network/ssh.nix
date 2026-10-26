# A machine's SSH, root by the machine's keys and never by a password, and on a fetched machine
# its builders as the user machine-cache, nix/cache/fetch.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  closing = config.machine.ssh.public == "until-healthy";
  rules = pkgs.writeText "machine-ssh.nft" (import ./ssh/input.nix);
  closer = pkgs.writeShellApplication {
    name = "machine-ssh-close";
    runtimeInputs = [
      config.services.tailscale.package
      pkgs.nftables
      pkgs.jq
      pkgs.coreutils
    ];
    text = import ./ssh/close.nix;
  };
  again = "${config.systemd.package}/bin/systemctl --no-block restart machine-ssh-close.service";
in
{
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users = {
    mutableUsers = false;
    users.root.openssh.authorizedKeys.keys = config.machine.keys;
  };

  # Remove our table on a firewall reload, including a switch to the repair setting.
  networking.nftables.extraDeletions = ''
    table inet machine-ssh
    delete table inet machine-ssh
  '';
  systemd.services = lib.mkIf closing {
    machine-ssh-close = {
      description = "Close public SSH while Tailscale is healthy";
      wantedBy = [ "multi-user.target" ];
      after = [
        "nftables.service"
        "tailscaled.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "machine-ssh";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = true;
        ExecStart = "${lib.getExe closer} ${rules}";
      };
    };
    # Queued after nftables finishes so a flushed table is restored without an ordering deadlock.
    nftables.serviceConfig = {
      ExecStartPost = lib.mkAfter [ again ];
      ExecReload = lib.mkAfter [ again ];
    };
  };
  systemd.timers.machine-ssh-close = lib.mkIf closing {
    description = "Check public SSH exposure every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:*:00";
      AccuracySec = "1s";
    };
  };
}
