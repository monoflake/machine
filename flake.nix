{
  description = "NixOS module and template for a Linux container host";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
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
      # Unstable beside the release, RFC vr5lw, as `pkgs.unstable`.
      nixosModules.machine = {
        imports = [
          disko.nixosModules.disko
          system
        ];
        nixpkgs.overlays = [
          (final: _: {
            unstable = import unstable { inherit (final.stdenv.hostPlatform) system; };
          })
        ];
      };

      lib.fleet = import ./system/nix/cache/fleet.nix { inherit (nixpkgs) lib; };

      # A test machine as a container in Docker, of the system and with the SSH keys given, which
      # `mise run local` starts, RFC n0o4l.
      lib.local =
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

      templates.machine = {
        path = system + "/template";
        description = "NixOS configuration for a Linux container host";
      };

      # The template as it stands, with the driver on and with a tunnel, both with the bound host's
      # units, as an exit node, as a peer relay, and the local machine, built for each system.
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
