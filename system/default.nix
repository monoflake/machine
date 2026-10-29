# What a machine is, NixOS with containerd, the host's driver, the tailnet, a firewall and bash, RFC
# vr5lw. Its disk is `boot/disk.nix`, its tools for hands `maintenance/`, its own flake `template/`.
{
  imports = [
    ./options.nix
    ./names.nix
    ./base.nix
    ./memory.nix
    ./boot
    ./network
    ./time
    # Ahead of `./containers`, as the order of the system's packages follows the imports.
    ./containers/runtimes.nix
    ./containers
    ./driver.nix
    ./nix
    ./maintenance
  ];

  # The system is the release, containerd and its runtimes unstable's, docs/releases.md.
  nixpkgs.overlays = [ (final: _: { inherit (final.unstable) containerd; }) ];
}
