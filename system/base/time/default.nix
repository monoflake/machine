# A machine's clock, chrony with its provider's source, its region's and Cloudflare's over NTS, off
# by default, docs/network.md.
{ config, lib, ... }:
let
  cfg = config.machine.time;
  provider = {
    oracle = [ "server 169.254.169.254 iburst prefer" ];
    azure = [ "refclock PHC /dev/ptp_hyperv poll 3 dpoll -2 offset 0 stratum 2 prefer" ];
    none = [ ];
  };
in
{
  config = lib.mkIf cfg.enable {
    services.chrony = {
      enable = true;
      servers = [ ];
      directory = "/var/lib/chrony";
      # RTC trimming conflicts with rtcsync.
      enableRTCTrimming = false;
      makestep.enable = false;
      extraConfig = lib.concatStringsSep "\n" (
        [
          "makestep 1 3"
          "rtcsync"
        ]
        ++ provider.${cfg.provider}
        ++ lib.optionals (config.machine.network.resolvers == "china") [
          "server ntp.aliyun.com iburst"
          "server ntp.tencent.com iburst"
        ]
        ++ [ "server time.cloudflare.com iburst nts" ]
      );
    };
  };
}
