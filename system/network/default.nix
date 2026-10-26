# A machine's network, DHCP or its provider's seed with fixed nameservers, nftables, the tailnet's
# interface trusted, the fence around the containers, the tunnel, and the ports its listeners keep.
{ config, lib, ... }:
let
  tailnet = config.services.tailscale.interfaceName;
  # The machine driver's port, DRIVE on a keypad, monoflake/driver's RFC 8c0rg.
  driver = 37483;
  entry = lib.toInt (lib.last (lib.splitString ":" config.machine.driver.entry));
  inherit (config.machine) conform;
  dhcp = !config.machine.network.seed;
in
{
  imports = [
    ./fence.nix
    ./seed
    ./ssh.nix
    ./tailnet.nix
    ./tunnel.nix
  ];

  networking = {
    useDHCP = lib.mkIf dhcp true;
    dhcpcd.extraConfig = lib.mkIf dhcp "nohook resolv.conf";
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    nftables.enable = true;
    firewall.trustedInterfaces = [ tailnet ];
    firewall.interfaces.${tailnet}.allowedTCPPorts = [ driver ];
  };

  # Ports no connection is given as its own, so the entry, the driver, conform's and any the machine
  # names find theirs free, monoflake/driver's RFC p95sv.
  boot.kernel.sysctl."net.ipv4.ip_local_reserved_ports" = lib.concatMapStringsSep "," toString (
    [
      entry
      driver
    ]
    ++ lib.optionals conform.enable [
      conform.entry
      conform.driver
    ]
    ++ config.machine.reservedPorts
  );
}
