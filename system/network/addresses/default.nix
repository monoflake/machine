# Public address discovery follows RFC co32d.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  discover = pkgs.writeShellApplication {
    name = "machine-addresses";
    runtimeInputs = [
      config.services.tailscale.package
      pkgs.curl
      pkgs.iproute2
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./discover.sh;
  };
in
{
  config = lib.mkIf config.machine.addresses.enable {
    systemd.services.machine-addresses = {
      description = "Discover the machine's public addresses";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "infinity";
        StateDirectory = "machine";
        UMask = "0077";
        ExecStart = "${lib.getExe discover} ${./parse.jq}";
      };
    };
    systemd.timers.machine-addresses = {
      description = "Discover public addresses at boot and every hour";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "0";
        OnUnitActiveSec = "1h";
        AccuracySec = "1s";
      };
    };
  };
}
