# A machine's Nix, flakes on, no channels, registry or installer tools.
{
  imports = [
    ./cache
    ./collect.nix
    ./update
    ./upgrade.nix
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # A path the bucket expired, or one uploaded after a miss, is asked again soon, docs/cache.md.
    narinfo-cache-positive-ttl = 3600;
    narinfo-cache-negative-ttl = 60;
  };
  nixpkgs.flake = {
    setNixPath = false;
    setFlakeRegistry = false;
  };
  system.disableInstallerTools = true;
}
