# A machine's place on the tailnet, joined at boot by the machine's auth key, unstable's Tailscale,
# and an exit node where the machine is one, docs/tailnet.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.machine.tailnet) exitNode;
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
    ];
  };
}
