# A machine whose provider gives no DHCP, its static addresses read at every boot from the
# provider's NoCloud seed and handed to systemd-networkd, docs/network.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  render = pkgs.callPackage ./package.nix { };
  boot = pkgs.writeShellApplication {
    name = "machine-seed-network";
    runtimeInputs = [
      render
      pkgs.coreutils
      pkgs.util-linux
      config.systemd.package
    ];
    text = builtins.readFile ./boot.sh;
  };
in
{
  config = lib.mkIf config.machine.network.seed {
    networking = {
      useDHCP = false;
      dhcpcd.enable = false;
      useNetworkd = true;
    };
    # Resolved off, which networkd would bring, so /etc/resolv.conf keeps the fixed nameservers a
    # container reaches, never resolved's stub on loopback.
    services.resolved.enable = false;
    systemd.network = {
      enable = true;
      # Online once the ethernet is, never waiting on tailscale0 or a bridge.
      wait-online.anyInterface = true;
    };
    environment.systemPackages = [ render ];

    # Wanted and never required by networkd, so a seed refused still lets it start.
    systemd.services.machine-seed-network = {
      description = "The machine's static addresses read from its provider's seed";
      wantedBy = [ "systemd-networkd.service" ];
      wants = [ "network-pre.target" ];
      before = [
        "systemd-networkd.service"
        "network-pre.target"
      ];
      after = [
        "local-fs.target"
        "systemd-udevd.service"
        "systemd-udev-trigger.service"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe boot;
      };
    };
  };
}
