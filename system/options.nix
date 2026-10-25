# What a machine's own flake sets, and nothing else, RFC vr5lw. A secret is a path to a file the
# machine holds, never its text.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  file = types.addCheck types.str (lib.hasPrefix "/");
in
{
  options = {
    machine = {
      disk = mkOption {
        type = types.str;
        description = "Block device to partition and install the system onto.";
        example = "/dev/vda";
      };
      keys = mkOption {
        type = types.listOf types.str;
        description = "SSH public keys authorized to log in as root.";
      };
      memory = mkOption {
        type = types.ints.positive;
        description = "Memory installed, in MiB, from which the swap file's size is derived.";
        example = 4096;
      };
      maintenance.enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to install the tools and shell aliases for maintaining the machine by hand.";
      };
      swap.compressor = mkOption {
        type = types.enum [
          "zstd"
          "lz4"
        ];
        default = "zstd";
        description = "Compressor zswap uses for swapped pages; lz4 for a weak processor.";
      };
      reservedPorts = mkOption {
        type = types.listOf types.port;
        default = [ ];
        example = [ 9100 ];
        description = "Ports kept out of the range Linux gives a connection its own port from, besides the entry's and the driver's, which are always kept, and conform's where it runs.";
      };
      # The ports are monoflake/platform's conform's own, code/tools/conform/src/instance.res, and
      # its bridge is a constant in network/bridge.nix.
      conform = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Whether monoflake/platform's conform runs a second driver on this machine, which opens its entry's port on its bridge, conform0, alone in NixOS's firewall and keeps both its ports; its bridge is fenced either way.";
        };
        entry = mkOption {
          type = types.port;
          default = 46879;
          description = "Port conform's entry listens on, reached by its containers at its bridge's address.";
        };
        driver = mkOption {
          type = types.port;
          default = 47483;
          description = "Port conform's driver answers its management on, on loopback.";
        };
      };
      upgrade = {
        flake = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "git+ssh://git@github.com/monoflake/cloud?dir=machines/<name>";
          description = "Flake the machine upgrades itself from each day, its own configuration; null for none.";
        };
        at = mkOption {
          type = types.str;
          default = "04:00";
          example = "13:00";
          description = "Time of day, in UTC, the machine checks its flake and switches to what it names.";
        };
        keyFile = mkOption {
          type = types.nullOr file;
          default = null;
          description = "Path to a file containing the SSH key the machine reads a private flake on GitHub with.";
        };
      };
      tailnet.authKeyFile = mkOption {
        type = types.nullOr file;
        default = null;
        description = "Path to a file containing a Tailscale auth key, used to join the tailnet at boot.";
      };
      driver = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to run the machine's driver, driver-machine, as the service driver-machine, and its entry as the service driver-machine-entry.";
        };
        package = mkOption {
          type = types.nullOr types.package;
          default = null;
          description = "A release of driver-machine the services run; null until releases are opened.";
        };
        override = mkOption {
          type = types.nullOr file;
          default = null;
          example = "/var/lib/driver-machine/dev/driver-machine";
          description = "Path to a driver-machine binary the services run in place of a release, set on a test machine alone.";
        };
        bindings = mkOption {
          type = types.listOf file;
          default = [ ];
          description = "Paths to files each containing a binding token for the driver.";
        };
        local = mkOption {
          type = types.nullOr file;
          default = null;
          example = "/var/lib/driver-machine/artifacts";
          description = "Directory the driver takes `file:` artifacts from, set on a test machine alone; null refuses them.";
        };
        entry = mkOption {
          type = types.str;
          default = "0.0.0.0:36879";
          example = "127.0.0.1:36879";
          description = "Address and port the entry listens on, plain HTTP, held by the socket driver-machine-entry.socket across the service driver-machine-entry's restart; every address by default, as the driver's, so a bound host's control reaches it at its private address, and the firewall keeps the port from the public interface.";
        };
        plain = mkOption {
          type = types.nullOr (types.strMatching "http://[^/?#@]+");
          default = null;
          example = "http://host.docker.internal:8787";
          description = "Origin, `http://` and a host and port, the driver may fetch an artifact from over plain HTTP, set on a local machine alone; null refuses every plain address.";
        };
      };
      tunnel = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to run a quick Cloudflare Tunnel, cloudflared, on a random trycloudflare.com address in front of the entry as the service tunnel, its address written to /run/tunnel/address.";
        };
        host = mkOption {
          type = types.str;
          example = "app-1.b1";
          description = "Host every request through the tunnel is rewritten to, the deployment's address `app-<id>.b<binding>` the entry chooses by.";
        };
        origin = mkOption {
          type = types.str;
          default = "http://${
            lib.replaceStrings [ "0.0.0.0:" ] [ "127.0.0.1:" ] config.machine.driver.entry
          }";
          defaultText = lib.literalExpression ''"http://''${config.machine.driver.entry}", every address written as loopback'';
          description = "URL the tunnel sends requests to, the entry on loopback by default.";
        };
        bound.enable = mkOption {
          type = types.bool;
          default = config.machine.driver.enable;
          defaultText = lib.literalExpression "config.machine.driver.enable";
          description = "Whether to run the named tunnel `driver-machine bind` gives, with no ingress rules, as the service bound-tunnel, and hold the private address it gives on the interface tunnel0 as the service bound-address; each waits until the host is bound, and both start again when it is bound again.";
        };
      };
    };
  };

  config.assertions = [
    {
      assertion = config.machine.keys != [ ];
      message = "machine.keys must not be empty, or no SSH key could log in as root.";
    }
    {
      assertion = config.machine.conform.enable -> config.machine.driver.enable;
      message = "machine.conform needs machine.driver.enable, as conform runs beside the live driver.";
    }
  ];
}
