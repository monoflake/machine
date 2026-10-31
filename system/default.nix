# What a fleet machine is above the base layer, containerd, the host's driver, its names, tunnel and
# updates, RFC vr5lw, docs/layers.md. Its disk is `boot/disk.nix`, its own flake `template/`.
{
  imports = [
    ./options.nix
    ./names.nix
    ./memory.nix
    ./boot
    ./network
    # Ahead of `./containers`, as the order of the system's packages follows the imports.
    ./containers/runtimes.nix
    ./containers
    ./driver.nix
    ./nix
  ];

  # The system is the release, containerd and its runtimes unstable's, docs/releases.md.
  nixpkgs.overlays = [ (final: _: { inherit (final.unstable) containerd; }) ];
}
