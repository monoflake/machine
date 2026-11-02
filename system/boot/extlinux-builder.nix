{ pkgs }:
let
  source = pkgs.applyPatches {
    name = "extlinux-synced-source";
    src = pkgs.path + "/nixos/modules/system/boot/loader/generic-extlinux-compatible";
    patches = [ ./extlinux-sync.patch ];
  };
in
pkgs.replaceVarsWith {
  src = "${source}/extlinux-conf-builder.sh";
  isExecutable = true;
  replacements = {
    path = pkgs.lib.makeBinPath [
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnugrep
    ];
    inherit (pkgs) bash;
  };
}
