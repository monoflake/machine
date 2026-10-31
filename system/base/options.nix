# What every machine sets, the fleet's and the self-hosted runners', and nothing else, RFC vr5lw.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.machine = {
    keys = mkOption {
      type = types.listOf types.str;
      description = "SSH public keys authorized to log in as root.";
    };
    memory = mkOption {
      type = types.ints.positive;
      description = "Memory installed, in MiB, from which the swap's size is derived.";
      example = 4096;
    };
    maintenance.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to install the tools and shell aliases for maintaining the machine by hand.";
    };
    swap = {
      compressor = mkOption {
        type = types.enum [
          "zstd"
          "lz4"
        ];
        default = "zstd";
        description = "Compressor zswap or zram uses for swapped pages; lz4 for a weak processor.";
      };
      size = mkOption {
        type = types.ints.positive;
        readOnly = true;
        default = import ./swap.nix config.machine.memory;
        defaultText = lib.literalMD "`machine.memory` through `base/swap.nix`";
        description = "Size of the swap in MiB, derived from the memory installed.";
      };
      zram = mkOption {
        type = types.bool;
        default = false;
        description = "Whether swap is a zram device of machine.swap.size, for a machine with no swap file of its own.";
      };
    };
    network = {
      resolvers = mkOption {
        type = types.enum [
          "global"
          "china"
        ];
        default = "global";
        description = "Fixed nameservers written to the plain resolv.conf file, Cloudflare and Google for global or AliDNS for china.";
      };
      buffer = mkOption {
        type = types.ints.positive;
        default = 33554432;
        example = 134217728;
        description = "Largest socket buffer in bytes, the cap a TCP connection's receive and send windows grow to, 32 MiB by default.";
      };
      seed = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the machine reads its static addresses at every boot from its provider's cloud-init NoCloud seed, the iso9660 disk labeled cidata, and runs systemd-networkd in place of DHCP, for a provider giving no DHCP and no router advertisement, docs/network.md.";
      };
    };
    time = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether chrony synchronizes the clock with provider and regional sources and Cloudflare over NTS.";
      };
      provider = mkOption {
        type = types.enum [
          "oracle"
          "azure"
          "none"
        ];
        default = "none";
        description = "Provider time source preferred by chrony, or none for regional sources and Cloudflare alone.";
      };
    };
  };

  config.assertions = [
    {
      assertion = config.machine.keys != [ ];
      message = "machine.keys must not be empty, or no SSH key could log in as root.";
    }
  ];
}
