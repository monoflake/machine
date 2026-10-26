# A builder handing small machines their systems through a bucket, and a machine taking its own so,
# docs/cache.md.
{ config, lib, ... }:
let
  cfg = config.machine.cache;
  directory = lib.hasPrefix "/" cfg.bucket;
in
{
  imports = [
    ./build.nix
    ./fetch.nix
  ];

  config = {
    assertions = [
      {
        assertion =
          cfg.inventory == null
          || (
            config.networking.hostName == cfg.inventory.name
            && config.machine.upgrade.at == cfg.inventory.at
            &&
              builtins.sort builtins.lessThan (map (b: if b.name == null then "" else b.name) cfg.fetch.builders)
              == cfg.inventory.builders
          );
        message = "machine ${config.networking.hostName}: cache inventory name, upgrade time or builder names differ";
      }
      {
        assertion =
          cfg.fetch.builders == [ ]
          || (
            (builtins.length cfg.fetch.builders == 1 && (builtins.head cfg.fetch.builders).name == null)
            || (
              lib.all (b: b.name != null && b.name != "") cfg.fetch.builders
              &&
                builtins.length (lib.unique (map (b: b.name) cfg.fetch.builders))
                == builtins.length cfg.fetch.builders
            )
          );
        message = "machine ${config.networking.hostName}: builder names must be present and unique except for one legacy unnamed builder";
      }
    ]
    ++ lib.optionals cfg.enable [
      {
        assertion = cfg.builder.self != null -> config.machine.upgrade.flake != null;
        message = "machine.cache.builder.self needs machine.upgrade.flake.";
      }
      {
        assertion = directory || cfg.credentials != null;
        message = "machine.cache.credentials must be set for a bucket on Cloudflare R2.";
      }
      {
        assertion =
          (cfg.builds != { } || cfg.builder.self != null)
          -> lib.all (key: key != null) [
            cfg.builder.signingKey
            cfg.builder.pointerKey
            cfg.builder.accessKey
          ];
        message = "machine.cache.builds needs machine.cache.builder's signingKey, pointerKey and accessKey.";
      }
    ];
  };
}
