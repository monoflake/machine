# Names and labels evaluated without a live network, docs/names.md.
{
  root ? ../.,
}:
let
  flake = builtins.getFlake ("path:" + toString root);
  inherit (flake.inputs.nixpkgs) lib;
  evaluated =
    extra:
    lib.nixosSystem {
      modules = [
        flake.nixosModules.machine
        (
          let
            original = import (root + /system/template/configuration.nix);
          in
          original
          // {
            machine = builtins.removeAttrs original.machine [
              "hostname"
              "prettyName"
            ];
          }
        )
        {
          nixpkgs.hostPlatform = "x86_64-linux";
        }
        extra
      ];
    };
  template = extra: (evaluated extra).config;
  defaults = template { };
  overrides = template {
    machine = {
      name = lib.mkForce "birch";
      hostname = lib.mkForce "birch-box";
      prettyName = lib.mkForce "Birch2";
    };
  };
  seed = template { machine.network.seed = true; };
  accepted = option: value: (evaluated { }).options.machine.${option}.type.check value;
  refused =
    option: value:
    !(builtins.tryEval (
      builtins.deepSeq
        (template {
          machine.${option} = lib.mkForce value;
        }).machine.${option}
        true
    )).success;
  labels = import ./labels.nix;
  tests = {
    defaults =
      defaults.machine.hostname == defaults.machine.name
      && defaults.networking.hostName == "alder"
      && defaults.machine.prettyName == "Alder";
    renamedDefaults =
      let
        cfg = template { machine.name = lib.mkForce "birch"; };
      in
      cfg.machine.hostname == "birch" && cfg.machine.prettyName == "Birch";
    required = lib.all (option: !((evaluated { }).options.machine.${option} ? default)) [
      "name"
      "region"
      "provider"
      "account"
    ];
    overrides =
      overrides.machine.name == "birch"
      && overrides.networking.hostName == "birch-box"
      && overrides.machine.prettyName == "Birch2";
    uppercaseName = refused "name" "Alder";
    underscoreName = refused "name" "alder_box";
    uppercaseHostname = refused "hostname" "Alder";
    underscoreHostname = refused "hostname" "alder_box";
    prettySpace = refused "prettyName" "Alder Box";
    prettyUnderscore = refused "prettyName" "Alder_Box";
    nameLength =
      accepted "name" (lib.concatStrings (lib.replicate 63 "a"))
      && refused "name" (lib.concatStrings (lib.replicate 64 "a"));
    nameStart = refused "name" "1alder" && refused "hostname" "-alder";
    unknownRegion = refused "region" "moon";
    unknownProvider = refused "provider" "example";
    emptyAccount = refused "account" "";
    unverifiedAccount = accepted "account" "any account label";
    tailnet = lib.elem "--hostname=birch" overrides.services.tailscale.extraSetFlags;
    tailnetAssertions = lib.all (a: a.assertion) overrides.assertions;
    machineInfo = overrides.environment.etc."machine-info".text == "PRETTY_HOSTNAME=Birch2\n";
    dhcp =
      lib.elem "hostname Birch2" (lib.splitString "\n" overrides.networking.dhcpcd.extraConfig)
      && lib.hasInfix "nohook resolv.conf" overrides.networking.dhcpcd.extraConfig;
    seed =
      !seed.networking.dhcpcd.enable && !(lib.hasInfix "hostname " seed.networking.dhcpcd.extraConfig);
    exportedLabels = flake.lib.labels == labels;
    regionEnum =
      (evaluated { }).options.machine.region.type.functor.payload.values == flake.lib.labels.regions;
    providerEnum =
      (evaluated { }).options.machine.provider.type.functor.payload.values == flake.lib.labels.providers;
    regionsAccepted = lib.all (accepted "region") labels.regions;
    providersAccepted = lib.all (accepted "provider") labels.providers;
  };
in
assert lib.assertMsg (lib.all (v: v) (builtins.attrValues tests))
  "Names evaluation failed for ${
    lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: v: !v) tests))
  }";
{
  inherit tests;
}
