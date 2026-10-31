# A fleet machine's ports kept for the driver, its tunnel, fence and public SSH, docs/network.md.
{ config, lib, ... }:
let
  # The machine driver's port, DRIVE on a keypad, monoflake/driver's RFC 8c0rg.
  driver = 37483;
  entry = lib.toInt (lib.last (lib.splitString ":" config.machine.driver.entry));
  inherit (config.machine) conform;
in
{
  imports = [
    ./addresses
    ./fence.nix
    ./ssh.nix
    ./tailnet.nix
    ./tunnel.nix
  ];

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
