# What every machine is, the fleet's and the self-hosted runners', NixOS with a firewall, the
# tailnet, SSH by key, its clock, swap and tools for hands, docs/layers.md.
{
  imports = [
    ./options.nix
    ./ground.nix
    ./memory.nix
    ./console.nix
    ./degraded.nix
    ./network.nix
    ./tcp.nix
    ./ssh.nix
    ./tailnet.nix
    ./time
    ./nix.nix
    # Ahead of `./seed`, as the order of the system's packages follows the imports.
    ./maintenance
    ./seed
  ];
}
