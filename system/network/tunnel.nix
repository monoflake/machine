# The way in from outside, a Cloudflare Tunnel ending TLS in front of the entry, RFC n0o4l.
# A quick tunnel's random address is written to `address` once it answers.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.monoflake.tunnel;
  # Where the service's own metrics answer, cloudflared's first default port.
  metrics = "127.0.0.1:20241";
  address = "/run/monoflake/tunnel/address";
  # An explicit empty configuration, so no `.cloudflared` or `/etc/cloudflared` is ever read, and a
  # map, as an empty file is logged as an error.
  empty = pkgs.writeText "cloudflared.yml" "{}";
  arguments = [
    (lib.getExe pkgs.cloudflared)
    "--config=${empty}"
    "tunnel"
    "--no-autoupdate"
    "--metrics=${metrics}"
    "--url=${cfg.origin}"
    "--http-host-header=${cfg.host}"
  ]
  ++ lib.optionals (cfg.tokenFile != null) [
    "run"
    "--token-file=%d/token"
  ];
  curl = "${lib.getExe pkgs.curl} -s --max-time 5";
  # Writes the address the edge gave the quick tunnel once it answers from here, as a name looked up
  # before its record exists stays unresolved in the asker's cache for minutes, seen on 2026-10-23.
  learned = pkgs.writeShellScript "monoflake-tunnel-address" ''
    for _ in $(seq 90); do
      host=$(${curl} -f http://${metrics}/quicktunnel | ${lib.getExe pkgs.jq} -r .hostname)
      if [ -n "$host" ] && ${curl} -o /dev/null "https://$host/"; then
        echo "https://$host" > ${address} && exit 0
      fi
      sleep 1
    done
    echo "monoflake-tunnel: the quick tunnel's address did not answer within 90 seconds" >&2
    exit 1
  '';
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.monoflake-tunnel = {
      description = "The way in from outside, a Cloudflare Tunnel to the entry";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs arguments;
        ExecStartPost = lib.mkIf (cfg.tokenFile == null) "${learned}";
        LoadCredential = lib.mkIf (cfg.tokenFile != null) "token:${cfg.tokenFile}";
        TimeoutStartSec = 180;
        Restart = "always";
        RestartSec = 5;
        # Removed when the service stops, so a stale address is never read.
        RuntimeDirectory = "monoflake/tunnel";
        # An outbound client and nothing more, under every hardening that leaves.
        DynamicUser = true;
        CapabilityBoundingSet = "";
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged @resources"
        ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        UMask = "0077";
      };
    };
  };
}
