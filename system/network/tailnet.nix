# A machine's place on the tailnet, joined at boot by the machine's auth key, unstable's Tailscale,
# and an exit node or a peer relay where the machine is one, docs/tailnet.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.machine.tailnet) exitNode relayPort routes;
  relay = relayPort != null;
  refusesRoutes = flag: !(lib.hasPrefix "--accept-routes" flag) || flag == "--accept-routes=false";
in
{
  assertions = [
    {
      assertion = lib.all refusesRoutes (
        config.services.tailscale.extraSetFlags ++ config.services.tailscale.extraUpFlags
      );
      message = "services.tailscale.extraSetFlags and extraUpFlags must not enable --accept-routes; only --accept-routes=false is allowed.";
    }
  ];
  services.tailscale = {
    enable = true;
    package = pkgs.unstable.tailscale;
    openFirewall = true;
    authKeyFile = config.machine.tailnet.authKeyFile;
    # The kernel forwarding an exit node or a subnet router needs.
    useRoutingFeatures = lib.mkIf (exitNode || routes != [ ]) "server";
    # The tailnet's resolver would replace the nameservers `network/default.nix` sets, which a
    # container cannot reach.
    extraSetFlags = [
      "--accept-dns=false"
      # An explicit empty list clears manual subnet routes while preserving an existing exit node.
      "--advertise-routes=${lib.concatStringsSep "," routes}"
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
