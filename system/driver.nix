# The machine's driver, monoflake/driver's driver-machine, root under every hardening that leaves
# containerd, its network namespaces and btrfs quota groups working, its RFC 8c0rg.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.monoflake.driver;
  inherit (pkgs.unstable)
    runc
    crun
    youki
    btrfs-progs
    ;
  binary = if cfg.override != null then cfg.override else lib.getExe' cfg.package "driver-machine";
  # What the container kind's containers are given addresses from, on a bridge of its own.
  bridge = "monoflake0";
  subnet = "10.88.0.0/16";
  # The most an artifact may be, a GiB.
  largest = 1073741824;
  arguments = [
    "--runc=${runc}/bin/runc"
    "--crun=${crun}/bin/crun"
    "--youki=${youki}/bin/youki"
    "--plugins=${pkgs.cni-plugins}/bin"
    "--bridge=${bridge}"
    "--subnet=${subnet}"
    "--btrfs=${btrfs-progs}/bin/btrfs"
    "--largest=${toString largest}"
    "--entry=${cfg.entry}"
  ]
  ++ map (file: "--bindings=${file}") cfg.bindings
  ++ lib.optional (cfg.local != null) "--local=${cfg.local}";
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.package != null) != (cfg.override != null);
        message = "monoflake.driver needs exactly one of package and override set.";
      }
    ];

    systemd.services.monoflake-driver = {
      description = "The machine's driver, driver-machine";
      wantedBy = [ "multi-user.target" ];
      wants = [ "containerd.service" ];
      after = [ "containerd.service" ];
      # `ip netns`, `btrfs` and the bridge's masquerade's `nft` are called by name besides the
      # binaries the arguments give.
      path = [
        pkgs.iproute2
        btrfs-progs
        pkgs.nftables
      ];
      # A test machine's override not copied yet leaves the service inactive, never restarting.
      unitConfig = {
        ConditionPathExists = lib.mkIf (cfg.override != null) cfg.override;
        RequiresMountsFor = [
          "/data"
          "/run/monoflake/secrets"
        ];
      };
      serviceConfig = {
        ExecStart = lib.escapeShellArgs ([ binary ] ++ arguments);
        # The token files read again, as the program does on SIGHUP.
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = 2;
        StateDirectory = "monoflake/driver";
        StateDirectoryMode = "0700";
        # Nothing making a mount namespace, where a namespace `ip netns` mounts would never reach
        # containerd, tried on buf on 2026-10-22; /proc/sys stays open, which the CNI plugins write.
        NoNewPrivileges = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        CapabilityBoundingSet = "~CAP_SYS_BOOT CAP_SYS_TIME CAP_SYS_RAWIO CAP_SYS_PACCT CAP_SYSLOG CAP_WAKE_ALARM CAP_MAC_ADMIN CAP_MAC_OVERRIDE CAP_LINUX_IMMUTABLE CAP_MKNOD";
      };
    };

    # A test machine's override is copied in by monoflake/driver's `dev`, which rsync carries.
    environment.systemPackages = lib.mkIf (cfg.override != null) [ pkgs.rsync ];
    systemd.tmpfiles.rules = lib.mkIf (cfg.local != null) [ "d ${cfg.local} 0755 root root -" ];
  };
}
