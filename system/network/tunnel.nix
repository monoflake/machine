# The way in from outside, a Cloudflare Tunnel ending TLS in front of the entry, RFC n0o4l, and the
# named tunnel a bound host's control reaches it through, monoflake/cloud's RFC rxmd9.
# A quick tunnel's random address is written to `address` once it answers.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.machine.tunnel;
  # Where each tunnel's own metrics answer, cloudflared's first two default ports.
  metrics = "127.0.0.1:20241";
  named = "127.0.0.1:20242";
  address = "/run/tunnel/address";
  # What `driver-machine bind` writes under the driver's state, monoflake/driver's `src/bind.rs`.
  bound = "/var/lib/driver-machine/state/bound";
  # The interface holding the host's private address, which the tunnel's route announces, named so
  # the `tun*` NixOS's dhcpcd.conf denies passes it over, and binding restarts no network service.
  interface = "tunnel0";
  ip = lib.getExe' pkgs.iproute2 "ip";
  # An explicit empty configuration, so no `.cloudflared` or `/etc/cloudflared` is ever read, and a
  # map, as an empty file is logged as an error.
  empty = pkgs.writeText "cloudflared.yml" "{}";
  cloudflared = [
    (lib.getExe pkgs.cloudflared)
    "--config=${empty}"
    "tunnel"
    "--no-autoupdate"
  ];
  quick = cloudflared ++ [
    "--metrics=${metrics}"
    "--url=${cfg.origin}"
    "--http-host-header=${cfg.host}"
  ];
  # No ingress rules, as the control reaches the host by its private address alone.
  run = cloudflared ++ [
    "--metrics=${named}"
    "run"
    "--token-file=%d/tunnel"
  ];
  curl = "${lib.getExe pkgs.curl} -s --max-time 5";
  # Writes the address the edge gave the quick tunnel once it answers from here, as a name looked up
  # before its record exists stays unresolved in the asker's cache for minutes, seen on 2026-10-23.
  learned = pkgs.writeShellScript "tunnel-address" ''
    for _ in $(seq 90); do
      host=$(${curl} -f http://${metrics}/quicktunnel | ${lib.getExe pkgs.jq} -r .hostname)
      if [ -n "$host" ] && ${curl} -o /dev/null "https://$host/"; then
        echo "https://$host" > ${address} && exit 0
      fi
      sleep 1
    done
    echo "tunnel: the quick tunnel's address did not answer within 90 seconds" >&2
    exit 1
  '';
  # An outbound client and nothing more, under every hardening that leaves.
  hardened = {
    Restart = "always";
    RestartSec = 5;
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
  online = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.services.tunnel = online // {
        description = "The way in from outside, a Cloudflare Tunnel to the entry";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = hardened // {
          ExecStart = lib.escapeShellArgs quick;
          ExecStartPost = "${learned}";
          TimeoutStartSec = 180;
          # Removed when the service stops, so a stale address is never read.
          RuntimeDirectory = "tunnel";
        };
      };
    })

    # Each unit waits until the host is bound, and `bound` takes a bind made again.
    (lib.mkIf cfg.bound.enable {
      # After the machine's own, as what reads the first token file takes it for the machine's.
      machine.driver.bindings = lib.mkAfter [ "${bound}/binding" ];

      systemd.services = {
        bound-tunnel = online // {
          description = "The named tunnel the host was bound with, to its private address";
          wantedBy = [ "multi-user.target" ];
          unitConfig.ConditionPathExists = "${bound}/tunnel";
          serviceConfig = hardened // {
            ExecStart = lib.escapeShellArgs run;
            LoadCredential = "tunnel:${bound}/tunnel";
          };
        };

        bound-address = {
          description = "The host's private address the control reaches it at, held on ${interface}";
          wantedBy = [ "multi-user.target" ];
          before = [ "bound-tunnel.service" ];
          unitConfig.ConditionPathExists = "${bound}/address";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStop = "-${ip} link delete ${interface}";
          };
          script = ''
            ${ip} link delete ${interface} 2> /dev/null || true
            ${ip} link add ${interface} type dummy
            ${ip} address add "$(cat ${bound}/address)" dev ${interface}
            ${ip} link set ${interface} up
          '';
        };

        bound = {
          description = "What the host was bound with taken again, its address, tunnel and token";
          serviceConfig.Type = "oneshot";
          # The tunnel stops where the control answered none, its condition then unmet.
          script = ''
            systemctl restart bound-address.service bound-tunnel.service
            systemctl try-reload-or-restart driver-machine.service
          '';
        };
      };

      # The address is the last file a bind writes, the tunnel's token written or removed before it.
      systemd.paths.bound = {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathChanged = "${bound}/address";
      };
    })
  ];
}
