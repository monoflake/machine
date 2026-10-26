# A machine's place on the tailnet, joined at boot by the machine's auth key, unstable's Tailscale,
# and an exit node or a peer relay where the machine is one, docs/tailnet.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.machine.tailnet) exitNode relayPort;
  relay = relayPort != null;
in
{
  services.tailscale = {
    enable = true;
    package = pkgs.unstable.tailscale;
    openFirewall = true;
    authKeyFile = config.machine.tailnet.authKeyFile;
    # The kernel's forwarding an exit node needs, which `tailscale set` does not turn on.
    useRoutingFeatures = lib.mkIf exitNode "server";
    # The tailnet's resolver would replace the nameservers `network/default.nix` sets, which a
    # container cannot reach.
    extraSetFlags = [
      "--accept-dns=false"
    ]
    ++ lib.optionals exitNode [
      "--advertise-exit-node"
      "--stateful-filtering=true"
    ]
    ++ lib.optionals relay [ "--relay-server-port=${toString relayPort}" ];
  };
  # The relay's port, which Tailscale leaves closed, accepted on input as `openFirewall` accepts
  # Tailscale's own, and kept from the ports Linux gives a connection.
  networking.firewall.allowedUDPPorts = lib.mkIf relay [ relayPort ];
  machine.reservedPorts = lib.mkIf relay [ relayPort ];
}
