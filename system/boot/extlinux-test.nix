{
  root ? ../..,
}:
let
  flake = builtins.getFlake ("path:" + toString root);
  inherit (flake.inputs.nixpkgs) lib;
  check =
    system:
    let
      cfg =
        (lib.nixosSystem {
          modules = [
            flake.nixosModules.machine
            (root + /system/template/configuration.nix)
            ({ lib, ... }: {
              nixpkgs.hostPlatform = system;
              boot.loader = {
                grub.enable = lib.mkForce false;
                timeout = 7;
                generic-extlinux-compatible = {
                  enable = true;
                  configurationLimit = 4;
                  mirroredBoots = [
                    { path = "/boot"; }
                    { path = "/mirror"; }
                  ];
                };
              };
              hardware.deviceTree.name = "vendor/board.dtb";
            })
          ];
        }).config;
      pkgs = import flake.inputs.nixpkgs { inherit system; };
      builder = import ./extlinux-builder.nix { inherit pkgs; };
      script = cfg.system.build.installBootLoader.text;
      expected = builtins.unsafeDiscardStringContext (toString builder);
    in
    {
      inherit system;
      patchedBuilder = toString builder;
      passed =
        lib.hasInfix "${expected} -g 4 -t 7 -n vendor/board.dtb -d '/boot'" script
        && lib.hasInfix "${expected} -g 4 -t 7 -n vendor/board.dtb -d '/mirror'" script;
    };
  tests = map check [
    "aarch64-linux"
    "x86_64-linux"
  ];
in
assert lib.all (test: test.passed) tests;
tests
