{ flake, keys }:
let
  inherit (flake.inputs.nixpkgs) lib;
  consumer =
    name: named:
    let
      inherit
        (lib.nixosSystem {
          modules = [
            flake.nixosModules.machine
            ../../../../template/configuration.nix
            {
              nixpkgs.hostPlatform = "x86_64-linux";
              networking.hostName = lib.mkForce name;
              machine.cache = {
                enable = true;
                bucket = "/var/lib/machine-cache-bucket";
                fetch.builders = lib.imap0 (
                  k: pointer:
                  {
                    inherit pointer;
                    nix = "example.com:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                    access = pointer;
                  }
                  // lib.optionalAttrs named { name = "a${toString (k + 1)}"; }
                ) (if named then keys else [ (builtins.head keys) ]);
              };
            }
          ];
        })
        config
        ;
      file = config.systemd.services.machine-cache-fetch.environment.MACHINE_CACHE_CONFIG;
    in
    assert lib.all (a: a.assertion) config.assertions;
    {
      file = toString file;
      derivation = file.drvPath;
    };
in
{
  c1 = consumer "c1" false;
  c2 = consumer "c2" true;
}
