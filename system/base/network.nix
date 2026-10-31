# A machine's network and host firewall, DHCP unless a seed gives its addresses, fixed nameservers
# and SSH on the tailnet, docs/network.md.
{ config, lib, ... }:
let
  dhcp = !config.machine.network.seed;
in
{
  networking = {
    useDHCP = lib.mkIf dhcp true;
    dhcpcd.extraConfig = lib.mkIf dhcp "nohook resolv.conf";
    nameservers =
      {
        global = [
          "1.1.1.1"
          "8.8.8.8"
        ];
        china = [
          "223.5.5.5"
          "223.6.6.6"
        ];
      }
      .${config.machine.network.resolvers};
    nftables.enable = true;
    firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [ 22 ];
  };
}
