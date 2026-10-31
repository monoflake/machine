# A fleet machine's Nix, its cache, collection and updates, the rest in base/nix.nix.
{
  imports = [
    ./cache
    ./collect.nix
    ./update
    ./upgrade.nix
  ];

  # A path the bucket expired, or one uploaded after a miss, is asked again soon, docs/cache.md.
  nix.settings = {
    narinfo-cache-positive-ttl = 3600;
    narinfo-cache-negative-ttl = 60;
  };
}
