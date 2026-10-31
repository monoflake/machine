# A fleet machine's memory, zswap in front of a swap file on the data disk, sized by base/swap.nix.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  device = "/data/swap/swapfile";
  # The swap unit's name, as systemd names it from the file's path.
  unit = utils.escapeSystemdPath device;
in
{
  # A container takes none, its memory and kernel being its host's.
  config = lib.mkIf (!config.boot.isContainer) {
    boot.kernelParams = [
      # zswap before the swap file, a fifth of the memory at most, its coldest written back.
      "zswap.enabled=1"
      "zswap.max_pool_percent=20"
      "zswap.shrinker_enabled=1"
    ];

    # A file in a subvolume of its own, so no snapshot holds it; lz4 is a module, so the compressor
    # is set once the system is up rather than on the kernel's line.
    swapDevices = [
      {
        inherit device;
        size = config.machine.swap.size;
        # Out of swap.target, which sysinit.target waits for, so a missing /data holds up no boot.
        # Kept in fstab, since switch-to-configuration-ng swaps off a device gone from it, main.rs.
        options = [ "noauto" ];
      }
    ];
    systemd = {
      tmpfiles.rules = [
        "w- /sys/module/zswap/parameters/compressor - - - - ${config.machine.swap.compressor}"
      ];
      services."mkswap-${unit}" = {
        unitConfig.RequiresMountsFor = [ "/data" ];
        preStart = "[ -d /data/swap ] || ${pkgs.unstable.btrfs-progs}/bin/btrfs subvolume create /data/swap";
      };
      # fstab's unit wanted by multi-user.target and before the data plane, in no boot target, so a
      # switch, which turns off only a swap gone from fstab, passes over it.
      units."${unit}.swap" = {
        overrideStrategy = "asDropin";
        text = ''
          [Unit]
          DefaultDependencies=no
          RequiresMountsFor=/data
          Before=umount.target containerd.service driver-machine.service
          Conflicts=umount.target
        '';
      };
      targets.multi-user.wants = [ "${unit}.swap" ];
    };
  };
}
