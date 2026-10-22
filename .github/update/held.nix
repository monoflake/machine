# The packages a machine made from the template holds, each name to its version.
flake: system:
let
  machine = builtins.getFlake flake;
  os = machine.inputs.nixpkgs.lib.nixosSystem {
    modules = [
      machine.nixosModules.machine
      (machine.outPath + "/system/template/configuration.nix")
      { nixpkgs.hostPlatform = system; }
    ];
  };
  inherit (os) config pkgs;
  inherit (machine.inputs.nixpkgs) lib;
  services = [
    config.boot.kernelPackages.kernel
    config.services.tailscale.package
    config.nix.package
    config.systemd.package
    pkgs.containerd
  ];
  parsed = package: builtins.parseDrvName package.name;
  named = package: {
    name = package.pname or (parsed package).name;
    value = package.version or (parsed package).version;
  };
  # The runtimes' images manifest.toml pins are held as a package is, by name and version.
  images = lib.mapAttrs (_: pin: pin.version) (
    lib.filterAttrs (_: lib.isAttrs) (
      builtins.fromTOML (builtins.readFile (machine.outPath + "/system/containers/manifest.toml"))
    )
  );
in
builtins.listToAttrs (map named (config.environment.systemPackages ++ services)) // images
