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

      # The template, as it stands and with the driver on as a test machine runs it, and the local
      # machine, each built as a machine of each system would be, so the module is held to them.
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
            monoflake.driver = {
              enable = true;
              override = "/var/lib/monoflake/dev/driver-machine";
              local = "/var/lib/monoflake/artifacts";
              bindings = [ "/var/lib/secrets/binding" ];
            };
          };
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
