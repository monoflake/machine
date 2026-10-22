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
in
builtins.listToAttrs (map named (config.environment.systemPackages ++ services))
