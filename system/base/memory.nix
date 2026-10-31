# Swap as zram where a machine asks, sized as the fleet's swap file is, by base/swap.nix.
{ config, lib, ... }:
{
  config = lib.mkIf (config.machine.swap.zram && !config.boot.isContainer) {
    zramSwap = {
      enable = true;
      algorithm = config.machine.swap.compressor;
      # The size alone bounds it, never a share of the memory.
      memoryPercent = 100;
      memoryMax = config.machine.swap.size * 1024 * 1024;
    };
  };
}
