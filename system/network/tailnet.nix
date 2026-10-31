# A fleet machine joining the tailnet by its auth key, as an exit node, a peer relay or an app
# connector where it is one, the rest in base/tailnet.nix, docs/tailnet.md.
{ config, lib, ... }:
let
  inherit (config.machine.tailnet)
    connector
    exitNode
    relayPort
    routes
    ;
  relay = relayPort != null;
in
{
  assertions = [
    {
      assertion = !connector || (!exitNode && routes == [ ]);
      message = "machine.tailnet.connector cannot be set beside machine.tailnet.exitNode or machine.tailnet.routes, whose flags would clear the routes the connector learned.";
    }
  ];
  services.tailscale = {
    authKeyFile = config.machine.tailnet.authKeyFile;
    # The kernel forwarding an exit node, a subnet router or an app connector needs.
    useRoutingFeatures = lib.mkIf (exitNode || routes != [ ] || connector) "server";
    # A route flag goes only where set, as one clears a connector's routes.
    extraSetFlags =
      lib.optionals (routes != [ ]) [ "--advertise-routes=${lib.concatStringsSep "," routes}" ]
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
