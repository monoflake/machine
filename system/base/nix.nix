# A machine's Nix, flakes on, no channels, registry or installer tools.
{
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
