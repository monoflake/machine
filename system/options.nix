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
      addresses.enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the machine learns its public IPv4 and IPv6 addresses at boot and every hour from Tailscale's netcheck and Cloudflare's trace, agreeing, into /var/lib/machine/addresses.json, RFC co32d.";
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
      ssh.public = mkOption {
        type = types.enum [
          "until-healthy"
          "open"
        ];
        default = "until-healthy";
        description = "Whether public SSH stays open or closes when Tailscale is healthy, reopening with an alarm after five consecutive unhealthy checks while closed, with alarms while open counting only states other than NeedsLogin once boot uptime exceeds 600 seconds.";
      };
      reservedPorts = mkOption {
        type = types.listOf types.port;
        default = [ ];
        example = [ 9100 ];
        description = "Ports kept out of the range Linux gives a connection its own port from, besides the entry's and the driver's, which are always kept, and conform's where it runs; a peer relay's port, machine.tailnet.relayPort, joins them where set.";
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
      # A builder handing small machines their systems through a bucket, and a machine taking its
      # own so, docs/cache.md.
      cache = {
        inventory = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                name = mkOption { type = types.str; };
                at = mkOption { type = types.str; };
                builders = mkOption { type = types.listOf types.str; };
              };
            }
          );
          default = null;
          description = "Inventory identity, upgrade time and builder names checked against the configuration.";
        };
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Whether the machine takes its roles in the cache, a builder's for `builds` and a fetched machine's for `fetch`, once the bucket and its keys exist.";
        };
        bucket = mkOption {
          type = types.str;
          example = "caches";
          description = "Bucket on Cloudflare R2 a builder hands its machines their systems through; an absolute path stands a directory in for it on a test machine.";
        };
        credentials = mkOption {
          type = types.nullOr file;
          default = null;
          description = "Path to an environment file holding the bucket's endpoint as MACHINE_CACHE_ENDPOINT, its URL as the provider's dashboard shows it, `https://` and a host with any port, the bucket as its path or not, or that host alone, and the token reaching it as AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY; null for a directory.";
        };
        builds = mkOption {
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                options = {
                  flake = mkOption {
                    type = types.str;
                    example = "git+ssh://git@github.com/monoflake/cloud?dir=machines/<name>";
                    description = "Flake the machine's system is built from, its own configuration, read as `nixosConfigurations.<name>`.";
                  };
                  at = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "14:30";
                    description = "First UTC slot time, or a single run time when slots is empty; null for manual runs.";
                  };
                  slots = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "UTC slot times at which every builder runs for this consumer.";
                  };
                  slotDays = mkOption {
                    type = types.listOf types.int;
                    default = [ ];
                    description = "Day offsets of the slots relative to the consumer upgrade date.";
                  };
                  builders = mkOption {
                    type = types.attrsOf (types.ints.between 1 3);
                    default = { };
                    description = "Builder names and priorities used for the daily slot order.";
                  };
                  gap = mkOption {
                    type = types.ints.positive;
                    default = 20;
                    description = "Minutes between slots and before an active claim expires.";
                  };
                  host = mkOption {
                    type = types.str;
                    default = name;
                    description = "Host the machine is reached at by ssh, through the tailnet where this machine runs one.";
                  };
                };
              }
            )
          );
          default = { };
          description = "Machines this one builds the system of and hands through the bucket, each by its name.";
        };
        builder = {
          data = mkOption {
            type = types.bool;
            default = false;
            description = "Whether a cache builder keeps evaluation, all builds including its own system, temporary files, fetcher caches and staging under /data/build, a btrfs subvolume limited to 10 GB; only its own system closure is copied to the main store before switching.";
          };
          self = mkOption {
            type = types.nullOr (
              types.enum [
                "cache"
                "build"
              ]
            );
            default = null;
            description = "Own upgrade mode of an inventory builder, cache first or a local build.";
          };
          signingKey = mkOption {
            type = types.nullOr file;
            default = null;
            description = "Path to a file containing the Nix secret key every path uploaded is signed with.";
          };
          pointerKey = mkOption {
            type = types.nullOr file;
            default = null;
            description = "Path to a file containing the SSH private key a pointer is signed with, by `ssh-keygen -Y sign -n machine-cache`.";
          };
          accessKey = mkOption {
            type = types.nullOr file;
            default = null;
            description = "Path to a file containing the SSH private key the builder reaches a machine's user machine-cache with.";
          };
          cap = mkOption {
            type = types.ints.positive;
            default = 5000000000;
            description = "Bytes the bucket may hold before a run refuses to upload";
          };
          store = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "local?root=/var/lib/machine-proof/root";
            description = "Nix store a run builds in, the machine's own when null; another root keeps a test machine that builds its own system from holding what it builds.";
          };
        };
        fetch = {
          builders = mkOption {
            type = types.listOf (
              types.submodule {
                options = {
                  name = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = "Required inventory name of the builder owning its pointer, except for one legacy unnamed builder.";
                  };
                  pointer = mkOption {
                    type = types.str;
                    description = "SSH public key the builder signs a pointer with.";
                  };
                  nix = mkOption {
                    type = types.str;
                    example = "builder-1:<base64>";
                    description = "Nix public key the builder signs the paths it uploads with.";
                  };
                  access = mkOption {
                    type = types.str;
                    description = "SSH public key the builder reaches the user machine-cache with.";
                  };
                };
              }
            );
            default = [ ];
            description = "Builders the machine takes its system from, each by its public keys; any makes it a fetched machine, whose daily upgrade at `machine.upgrade.at` fetches its system in place of evaluating its flake.";
          };
          from = mkOption {
            type = types.listOf types.str;
            default = [
              "100.64.0.0/10"
              "fd7a:115c:a1e0::/48"
            ];
            description = "Addresses a builder's access key is taken from, the tailnet's.";
          };
        };
      };
      # The machine's place on the tailnet and whether it is an exit node, a peer relay or an app
      # connector, docs/tailnet.md.
      tailnet = {
        routes = mkOption {
          type = types.listOf (types.addCheck types.str (import ./network/cidr.nix { inherit lib; }));
          default = [ ];
          example = [ "198.51.100.7/32" ];
          description = "IPv4 or IPv6 CIDRs advertised as subnet routes, replacing all manually configured subnet routes and enabling kernel forwarding when nonempty; emptying it does not withdraw routes already advertised, docs/tailnet.md.";
        };
        authKeyFile = mkOption {
          type = types.nullOr file;
          default = null;
          description = "Path to a file containing a Tailscale auth key, used to join the tailnet at boot.";
        };
        exitNode = mkOption {
          type = types.bool;
          default = false;
          description = "Whether the machine advertises itself as a Tailscale exit node, forwarding with Tailscale's stateful filtering on, which the tailnet's admin has to approve before any traffic leaves through it; turning it off does not withdraw an advertisement already made, docs/tailnet.md.";
        };
        # Never beside an exit node or routes, whose flags clear the routes a connector learned.
        connector = mkOption {
          type = types.bool;
          default = false;
          description = "Whether the machine advertises itself as a Tailscale app connector, forwarding the traffic for the domains the tailnet's policy names, which cannot be set beside exitNode or routes; turning it off does not withdraw an advertisement already made nor the routes it learned, docs/tailnet.md.";
        };
        # Never 0, which Tailscale reads as a random port the firewall could not open.
        relayPort = mkOption {
          type = types.nullOr (types.ints.between 1 65535);
          default = null;
          example = 40000;
          description = "Fixed UDP port the machine serves as a Tailscale peer relay on, opened in its firewall and kept out of the range Linux gives a connection its own port from, which the tailnet's policy has to grant before any client relays through it; null for none, and removing the option does not stop the relay Tailscale already runs, docs/tailnet.md.";
        };
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
          defaultText = lib.literalMD "the release `system/containers/manifest.lock` locks, or `null`";
          description = "driver-machine package the services run; by default, where the driver is enabled and no override is set, the release system/containers/manifest.lock locks, this machine's architecture's archive fetched from GitHub Releases by its SHA-256, and null while the lock holds none.";
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
          example = "0a1b2c3d.b1";
          description = "Host every request through the tunnel is rewritten to, the deployment's address `<id in 8 hex>.b<binding>` the entry chooses by.";
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
