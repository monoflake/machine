# A machine's network, DHCP with fixed nameservers, nftables, the tailnet's interface trusted, and
# the tunnel.
let
  tailnet = "tailscale0";
  # The machine driver's port, DRIVE on a keypad, monoflake/driver's RFC 8c0rg.
  driver = 37483;
in
{
  imports = [
    ./ssh.nix
    ./tailnet.nix
    ./tunnel.nix
  ];

  networking = {
    useDHCP = true;
    dhcpcd.extraConfig = "nohook resolv.conf";
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    nftables.enable = true;
    firewall.trustedInterfaces = [ tailnet ];
    firewall.interfaces.${tailnet}.allowedTCPPorts = [ driver ];
  };
}
