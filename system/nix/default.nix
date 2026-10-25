# A machine's Nix, flakes on, no channels, registry or installer tools.
{
  imports = [
    ./cache
    ./collect.nix
    ./upgrade.nix
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nixpkgs.flake = {
    setNixPath = false;
    setFlakeRegistry = false;
  };
  system.disableInstallerTools = true;
}
