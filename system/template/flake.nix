{
  description = "NixOS configuration for a Linux container host";

  inputs = {
    machine.url = "github:monoflake/machine";
    nixpkgs.follows = "machine/nixpkgs";
  };

  outputs =
    { machine, nixpkgs, ... }:
    {
      # The system is the hardware configuration's, `nixpkgs.hostPlatform`.
      nixosConfigurations.machine = nixpkgs.lib.nixosSystem {
        modules = [
          machine.nixosModules.machine
          ./configuration.nix
        ];
      };
    };
}
