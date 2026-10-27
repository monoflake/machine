# The machine's driver, monoflake/driver's driver-machine, root under every hardening that leaves
# containerd, its network namespaces and btrfs quota groups working, its RFC 8c0rg.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.machine.driver;
  # The release manifest.lock locks, this machine's architecture's archive fetched by its SHA-256,
  # and null until the lock holds one.
  pin = (builtins.fromTOML (builtins.readFile ./containers/manifest.lock)).driver-machine or null;
  released =
    if pin == null then
      null
    else
      pkgs.stdenvNoCC.mkDerivation {
        pname = "driver-machine";
        inherit (pin) version;
        src = pkgs.fetchurl {
          name = "driver-machine-${pin.version}-linux-${pkgs.stdenv.hostPlatform.parsed.cpu.name}.tar.gz";
          inherit (pin.${pkgs.stdenv.hostPlatform.system}) url sha256;
        };
        sourceRoot = ".";
        # The binary is static against musl, so nothing in it is patched or stripped.
        dontFixup = true;
        installPhase = ''
          runHook preInstall
          install -Dm755 driver-machine "$out/bin/driver-machine"
          install -Dm644 -t "$out/share/licenses/driver-machine" LICENSE-MIT LICENSE-APACHE
          runHook postInstall
        '';
        meta = {
          mainProgram = "driver-machine";
          platforms = lib.platforms.linux;
          license = with lib.licenses; [
            mit
            asl20
          ];
        };
      };
  inherit (pkgs.unstable)
    runc
    crun
    youki
    btrfs-progs
    ;
  binary = if cfg.override != null then cfg.override else lib.getExe' cfg.package "driver-machine";
  # What the container kind's containers are given addresses from, on a bridge of its own.
  bridge = (import ./network/bridge.nix).live;
  subnet = "10.88.0.0/16";
  # The entry's port, from the same option the entry listens on.
  port = lib.toInt (lib.last (lib.splitString ":" cfg.entry));
  # The most an artifact may be, a GiB.
  largest = 1073741824;
  # Where the driver roots each container's runtime binary against the store's collector, written
  # with no ReadWritePaths, which would give the unit the mount namespace `ip netns` cannot cross.
  roots = "/nix/var/nix/gcroots/driver-machine";
  arguments = [
    "--runc=${runc}/bin/runc"
    "--crun=${crun}/bin/crun"
    "--youki=${youki}/bin/youki"
    "--roots=${roots}"
    # Each root made by nix-store, so a collection already running sees it.
    "--nix-store=${config.nix.package}/bin/nix-store"
    "--plugins=${pkgs.cni-plugins}/bin"
    "--bridge=${bridge}"
    "--subnet=${subnet}"
    "--entry=${toString port}"
    "--btrfs=${btrfs-progs}/bin/btrfs"
    "--largest=${toString largest}"
  ]
  ++ map (file: "--bindings=${file}") cfg.bindings
  ++ lib.optional (cfg.local != null) "--local=${cfg.local}"
  ++ lib.optional (cfg.plain != null) "--plain=${cfg.plain}";
  # The group given containerd's socket, so the entry reads it without being root.
  group = "containerd";
  socket = "/run/containerd/containerd.sock";
in
{
  config = lib.mkIf cfg.enable {
    # A test machine's override stands in for the release, so the default gives way to it.
    machine.driver.package = lib.mkDefault (if cfg.override != null then null else released);

    assertions = [
      {
        assertion = (cfg.package != null) != (cfg.override != null);
        message = "machine.driver needs exactly one of package and override set.";
      }
    ];

    systemd = {
      services = {
        driver-machine = {
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
              "/run/driver-machine/secrets"
            ];
          };
          serviceConfig = {
            ExecStart = lib.escapeShellArgs ([ binary ] ++ arguments);
            # The token files read again, as the program does on SIGHUP.
            ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
            Restart = "on-failure";
            RestartSec = 2;
            StateDirectory = "driver-machine/state";
            StateDirectoryMode = "0700";
            # No mount namespace, where one `ip netns` mounts would never reach containerd, tried
            # on a test machine on 2026-10-22; /proc/sys stays open, which the CNI plugins write.
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

        # The entry, the same binary's command `entry`, needing nothing of the driver, RFC rmll5;
        # its listener its socket's, so a connection made while it restarts waits, RFC ehm48.
        driver-machine-entry = {
          description = "The machine's entry, driver-machine entry";
          wantedBy = [ "multi-user.target" ];
          wants = [ "containerd.service" ];
          requires = [ "driver-machine-entry.socket" ];
          after = [
            "containerd.service"
            "driver-machine-entry.socket"
          ];
          # Restarted by a switch rather than stopped before it, so its socket waits a moment alone.
          stopIfChanged = false;
          unitConfig = {
            ConditionPathExists = lib.mkIf (cfg.override != null) cfg.override;
            # Never started without the data disk containerd keeps its containers on.
            RequiresMountsFor = [ "/data" ];
            # Started again however often it ends, as the data plane is never given up on.
            StartLimitIntervalSec = 0;
          };
          serviceConfig = {
            ExecStart = lib.escapeShellArgs [
              binary
              "entry"
              "--listen=${cfg.entry}"
              "--containerd=${socket}"
              "--subnet=${subnet}"
            ];
            Restart = "always";
            RestartSec = 1;
            # The program answers what it has begun within 10 s of SIGTERM, then exits.
            TimeoutStopSec = 15;
            # containerd's socket and its listener and nothing more, under every hardening left.
            DynamicUser = true;
            SupplementaryGroups = [ group ];
            CapabilityBoundingSet = "";
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
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
        # Given each time containerd makes it, as its own setting takes a group's number alone.
        containerd.serviceConfig.ExecStartPost = "${pkgs.coreutils}/bin/chgrp ${group} ${socket}";
      };

      # The entry's address, held by systemd across the entry's restart, RFC ehm48; `--listen`
      # names it still, for what reads the entry's address from its command line.
      sockets.driver-machine-entry = {
        description = "The machine's entry's listener, held while the entry restarts";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ cfg.entry ];
        # Not listening without the data disk, which a connection would retry the entry against,
        # and not before sockets.target, so the disk holds up nothing else at boot.
        unitConfig = {
          DefaultDependencies = false;
          RequiresMountsFor = [ "/data" ];
        };
        requires = [ "sysinit.target" ];
        after = [ "sysinit.target" ];
        # Listening before the driver starts the containers that reach it, RFC ehm48.
        before = [
          "driver-machine.service"
          "shutdown.target"
        ];
        conflicts = [ "shutdown.target" ];
      };

      # conform's driver, a transient unit conform starts, given the same need by a drop-in alone.
      units."conform.service" = lib.mkIf config.machine.conform.enable {
        overrideStrategy = "asDropin";
        text = ''
          [Unit]
          RequiresMountsFor=/data
        '';
      };

      tmpfiles.rules = [
        "d ${roots} 0755 root root -"
      ]
      ++ lib.optional (cfg.local != null) "d ${cfg.local} 0755 root root -";
    };
    users.groups.${group} = { };

    # A test machine's override is copied in by monoflake/driver's `dev`, which rsync carries.
    environment.systemPackages = lib.mkIf (cfg.override != null) [ pkgs.rsync ];
  };
}
