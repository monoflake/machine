# A machine on the tailnet, the newest Tailscale, its resolver and routes refused, docs/tailnet.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
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
    # The one package named onto nixpkgs-unstable, docs/releases.md.
    package = pkgs.latest.tailscale;
    openFirewall = true;
    # The tailnet's resolver would replace the nameservers `network.nix` sets, which a container
    # cannot reach, and CI alone moves Tailscale, docs/tailnet.md. First, as a layer adds its own.
    extraSetFlags = lib.mkBefore [
      "--accept-dns=false"
      "--auto-update=false"
    ];
  };
  # tailscaled dials its control once the machine holds an address, docs/tailnet.md.
  systemd.services.tailscaled = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };
  networking.dhcpcd.wait = lib.mkDefault "ipv4";
}
