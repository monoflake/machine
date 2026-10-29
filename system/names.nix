# A machine's network, static and display names, docs/names.md.
{ config, lib, ... }:
{
  networking.hostName = config.machine.hostname;
  services.tailscale.extraSetFlags = lib.mkAfter [ "--hostname=${config.machine.name}" ];
  environment.etc."machine-info".text = "PRETTY_HOSTNAME=${config.machine.prettyName}\n";
  networking.dhcpcd.extraConfig = lib.mkIf (
    !config.machine.network.seed
  ) "hostname ${config.machine.prettyName}";
}
