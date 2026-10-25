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

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = directory || cfg.credentials != null;
        message = "machine.cache.credentials must be set for a bucket on Cloudflare R2.";
      }
      {
        assertion =
          cfg.builds != { }
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
