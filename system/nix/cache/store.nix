# A builder's scratch work and evaluation stay on the data disk, docs/cache.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.machine.cache;
  builds = cfg.builds != { } || cfg.builder.self != null;
  units =
    lib.concatMap (name: [
      "machine-cache-${name}"
      "machine-cache-now@${name}"
    ]) (builtins.attrNames cfg.builds)
    ++ lib.optional (cfg.builder.self != null) "machine-cache-self";
  environment = {
    TMPDIR = "/data/build/tmp";
    XDG_CACHE_HOME = "/data/build/cache";
    NIX_LOG_DIR = "/data/build/log";
  };
  storage = {
    requires = [ "machine-cache-build-store.service" ];
    after = [ "machine-cache-build-store.service" ];
    unitConfig.RequiresMountsFor = [ "/data" ];
    inherit environment;
  };
in
{
  config = lib.mkIf cfg.builder.data {
    assertions = [
      {
        assertion = config.fileSystems ? "/data" && config.fileSystems."/data".fsType == "btrfs";
        message = "machine.cache.builder.data needs /data mounted as btrfs with simple quotas from installation so build work never fills the root filesystem.";
      }
      {
        assertion = cfg.enable && builds;
        message = "machine.cache.builder.data needs an enabled cache builder.";
      }
      {
        assertion = !config.system.autoUpgrade.enable;
        message = "machine.cache.builder.data needs machine.cache.builder.self for own upgrades so every build uses the data disk and run cleanup.";
      }
      {
        assertion = cfg.builder.store == "local?root=/data/build/root";
        message = "machine.cache.builder.data needs machine.cache.builder.store = local?root=/data/build/root to keep builds off the root filesystem.";
      }
    ];
    machine.cache.builder.store = lib.mkDefault "local?root=/data/build/root";
    nix.settings.build-dir = "/data/build/builds";
    systemd.services = lib.genAttrs units (_: storage) // {
      nix-daemon = lib.recursiveUpdate storage {
        environment.TMPDIR = "/data/build/daemon-tmp";
      };
      machine-cache-build-store = {
        description = "Prepare the builder's subvolume and quota on the data disk";
        unitConfig.RequiresMountsFor = [ "/data" ];
        serviceConfig.Type = "oneshot";
        path = [
          pkgs.btrfs-progs
          pkgs.coreutils
        ];
        script = ''
          if ! btrfs subvolume show /data/build >/dev/null 2>&1; then
            if [ -e /data/build ] || [ -L /data/build ]; then
              echo "machine-cache: refusing existing /data/build; follow docs/cache.md#existing-directory-migration before enabling machine.cache.builder.data" >&2
              exit 1
            fi
            btrfs subvolume create /data/build
          fi
          btrfs qgroup limit 10000000000 /data/build
          install -d -m 0755 /data/build/root /data/build/builds /data/build/log
          install -d -m 0700 /data/build/tmp /data/build/cache /data/build/daemon-tmp
        '';
      };
    };
  };
}
