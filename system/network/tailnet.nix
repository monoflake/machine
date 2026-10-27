# A machine's place on the tailnet, joined at boot by the machine's auth key, unstable's Tailscale,
# and an exit node, a peer relay or an app connector where the machine is one, docs/tailnet.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.machine.tailnet)
    connector
    exitNode
    relayPort
    routes
    ;
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
    {
      assertion = !connector || (!exitNode && routes == [ ]);
      message = "machine.tailnet.connector cannot be set beside machine.tailnet.exitNode or machine.tailnet.routes, whose flags would clear the routes the connector learned.";
    }
  ];
  services.tailscale = {
    enable = true;
    package = pkgs.unstable.tailscale;
    openFirewall = true;
    authKeyFile = config.machine.tailnet.authKeyFile;
    # The kernel forwarding an exit node, a subnet router or an app connector needs.
    useRoutingFeatures = lib.mkIf (exitNode || routes != [ ] || connector) "server";
    # The tailnet's resolver would replace the nameservers `network/default.nix` sets, which a
    # container cannot reach. A route flag goes only where set, as one clears a connector's routes.
    extraSetFlags = [
      "--accept-dns=false"
    ]
    ++ lib.optionals (routes != [ ]) [ "--advertise-routes=${lib.concatStringsSep "," routes}" ]
    ++ lib.optionals exitNode [
      "--advertise-exit-node"
      "--stateful-filtering=true"
    ]
    ++ lib.optionals connector [
      "--advertise-connector"
      "--stateful-filtering=true"
    ]
    ++ lib.optionals relay [ "--relay-server-port=${toString relayPort}" ];
  };
  # The relay's port, which Tailscale leaves closed, accepted on input as `openFirewall` accepts
  # Tailscale's own, and kept from the ports Linux gives a connection.
  networking.firewall.allowedUDPPorts = lib.mkIf relay [ relayPort ];
  machine.reservedPorts = lib.mkIf relay [ relayPort ];
}
