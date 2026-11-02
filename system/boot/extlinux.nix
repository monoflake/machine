{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.boot.loader.generic-extlinux-compatible;
  loader = config.boot.loader;
  tree = config.hardware.deviceTree;
  builder = import ./extlinux-builder.nix { inherit pkgs; };
  timeout = if loader.timeout == null then "-1" else toString loader.timeout;
  args =
    "-g ${toString cfg.configurationLimit} -t ${timeout}"
    + lib.optionalString (tree.name != null) " -n ${tree.name}"
    + lib.optionalString (!cfg.useGenerationDeviceTree) " -r";
in
{
  config = lib.mkIf cfg.enable {
    system.build.installBootLoader = lib.mkForce (
      pkgs.writeScript "install-extlinux-conf.sh" (
        ''
          #!${pkgs.runtimeShell}
          set -e
        ''
        + lib.concatMapStrings (boot: ''
          ${builder} ${args} -d '${boot.path}' -c "$@"
        '') cfg.mirroredBoots
      )
    );
  };
}
