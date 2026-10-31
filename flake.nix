{
  description = "NixOS module and template for a Linux container host";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    latest.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      unstable,
      latest,
      disko,
      ...
    }:
    let
      system = ./system;
      linux = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      systems = linux ++ [ "aarch64-darwin" ];
      each = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      # What every machine is, docs/layers.md, with unstable as `pkgs.unstable` and the named
      # exceptions newer still as `pkgs.latest`, RFC vr5lw and docs/releases.md.
      nixosModules.base = {
        imports = [ (system + "/base") ];
        nixpkgs.overlays = [
          (final: _: {
            unstable = import unstable { inherit (final.stdenv.hostPlatform) system; };
            latest = import latest { inherit (final.stdenv.hostPlatform) system; };
          })
        ];
      };

      # A fleet machine, the base layer and the driver, containers and updates above it.
      nixosModules.machine = {
        imports = [
          disko.nixosModules.disko
          self.nixosModules.base
          system
        ];
      };

      lib = {
        swap = import ./system/base/swap.nix;
        labels = import ./system/labels.nix;
        fleet = import ./system/nix/cache/fleet.nix { inherit (nixpkgs) lib; };

        # A test machine as a container in Docker, of the system and with the SSH keys given, which
        # `mise run local` starts, RFC n0o4l.
        local =
          { system, keys }:
          nixpkgs.lib.nixosSystem {
            modules = [
              self.nixosModules.machine
              ./local
              {
                nixpkgs.hostPlatform = system;
                machine.keys = keys;
              }
            ];
          };
      };

      templates.machine = {
        path = system + "/template";
        description = "NixOS configuration for a Linux container host";
      };

      # The template as it stands, with the driver, with a tunnel, as an exit node and a peer relay,
      # the base layer alone, and the local machine, built for each system.
      checks = nixpkgs.lib.genAttrs linux (
        s:
        let
          template =
            extra:
            (nixpkgs.lib.nixosSystem {
              modules = [
                self.nixosModules.machine
                (system + "/template/configuration.nix")
                { nixpkgs.hostPlatform = s; }
                extra
              ];
            }).config.system.build.toplevel;
        in
        {
          machine = template { };
          driver = template {
            machine.driver = {
              enable = true;
              override = "/var/lib/driver-machine/dev/driver-machine";
              local = "/var/lib/driver-machine/artifacts";
              bindings = [ "/var/lib/secrets/binding" ];
            };
          };
          tunnel = template {
            machine.driver = {
              enable = true;
              override = "/var/lib/driver-machine/dev/driver-machine";
            };
            machine.tunnel = {
              enable = true;
              host = "0a1b2c3d.b1";
            };
          };
          # The base layer alone, as a deployment's runner takes it, with no option of the fleet's.
          base =
            (nixpkgs.lib.nixosSystem {
              modules = [
                self.nixosModules.base
                {
                  nixpkgs.hostPlatform = s;
                  machine = {
                    keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderReplaceWithYourOwnPublicKey0000" ];
                    memory = 12288;
                    swap.zram = true;
                    time.enable = true;
                  };
                  boot.loader.systemd-boot.enable = true;
                  fileSystems."/" = {
                    device = "/dev/disk/by-partlabel/root";
                    fsType = "ext4";
                  };
                  system.stateVersion = "26.05";
                }
              ];
            }).config.system.build.toplevel;
          exitNode = template { machine.tailnet.exitNode = true; };
          relay = template { machine.tailnet.relayPort = 40000; };
          local =
            (self.lib.local {
              system = s;
              keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderReplaceWithYourOwnPublicKey0000" ];
            }).config.system.build.toplevel;
        }
      );

      formatter = each (pkgs: pkgs.nixfmt);
    };
}
