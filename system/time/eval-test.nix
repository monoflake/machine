# Render each source policy without building chrony or reaching a time server.
{
  root ? ../..,
  base ? builtins.getEnv "MACHINE_TIME_BASE",
}:
let
  flake = builtins.getFlake ("path:" + toString root);
  inherit (flake.inputs.nixpkgs) lib;
  template =
    source: extra:
    (lib.nixosSystem {
      modules = [
        source.nixosModules.machine
        (source.outPath + "/system/template/configuration.nix")
        { nixpkgs.hostPlatform = "x86_64-linux"; }
        extra
      ];
    }).config;
  off = template flake { };
  without = template flake { disabledModules = [ ./default.nix ]; };
  # Keep the upstream renderings readable during evaluation without realizing derivations.
  rendered = _: previous: {
    writeText =
      name: text:
      if name == "chrony.conf" then builtins.toFile name text else previous.writeText name text;
    writeTextFile =
      args:
      if args.name == "fence.nft" then
        builtins.toFile args.name args.text
      else
        previous.writeTextFile args;
  };
  firewall = cfg: cfg.networking.nftables.tables.nixos-fw.content;
  sources =
    text:
    lib.filter (
      line:
      lib.any (prefix: lib.hasPrefix prefix line) [
        "server "
        "pool "
        "refclock "
      ]
    ) (lib.splitString "\n" text);
  cases = lib.genAttrs [ "oracle" "azure" "none" ] (
    provider:
    lib.genAttrs [ "global" "china" ] (
      resolvers:
      let
        cfg = template flake {
          nixpkgs.overlays = [ rendered ];
          machine = {
            time = {
              enable = true;
              inherit provider;
            };
            network = { inherit resolvers; };
          };
        };
        command = cfg.systemd.services.chronyd.serviceConfig.ExecStart;
        configuration = builtins.readFile (builtins.head (builtins.match ".* -f ([^ ]+).*" command));
        lines = lib.filter (line: line != "") (lib.splitString "\n" configuration);
        expected =
          lib.optionals (provider == "oracle") [ "server 169.254.169.254 iburst prefer" ]
          ++ lib.optionals (provider == "azure") [
            "refclock PHC /dev/ptp_hyperv poll 3 dpoll -2 offset 0 stratum 2 prefer"
          ]
          ++ lib.optionals (resolvers == "china") [
            "server ntp.aliyun.com iburst"
            "server ntp.tencent.com iburst"
          ]
          ++ [ "server time.cloudflare.com iburst nts" ];
      in
      {
        inherit configuration;
        tests = {
          exactSources = sources configuration == expected;
          chronyEnabled = cfg.services.chrony.enable;
          timesyncdDisabled = !cfg.services.timesyncd.enable;
          timesyncdAbsent = !(cfg.systemd.services ? systemd-timesyncd);
          step = lib.filter (lib.hasPrefix "makestep ") lines == [ "makestep 1 3" ];
          rtc =
            lib.elem "rtcsync" lines
            && !(lib.any (lib.hasPrefix "rtcfile ") lines)
            && !(lib.any (lib.hasPrefix "rtcautotrim ") lines);
          drift =
            lib.filter (lib.hasPrefix "driftfile ") lines == [
              "driftfile /var/lib/chrony/chrony.drift"
            ];
          noInboundChanges = firewall cfg == firewall off;
          validAssertions = lib.all (a: a.assertion) cfg.assertions;
        };
      }
    )
  );
  driver = {
    enable = true;
    override = "/var/lib/driver-machine/dev/driver-machine";
  };
  fencedOff = template flake {
    nixpkgs.overlays = [ rendered ];
    machine = { inherit driver; };
  };
  fencedOn = template flake {
    nixpkgs.overlays = [ rendered ];
    machine = {
      inherit driver;
      time = {
        enable = true;
        provider = "oracle";
      };
    };
  };
  fence =
    cfg:
    builtins.readFile (
      lib.last (lib.splitString " " cfg.systemd.services.fence.serviceConfig.ExecStart)
    );
  tests = {
    defaultOff = !off.machine.time.enable && off.machine.time.provider == "none";
    chronyAbsentOff = !off.services.chrony.enable && !(off.systemd.services ? chronyd);
    timesyncdUnchangedOff = off.services.timesyncd.enable == without.services.timesyncd.enable;
    unchangedOff = off.system.build.toplevel.drvPath == without.system.build.toplevel.drvPath;
    fallbackAlone =
      sources cases.none.global.configuration == [ "server time.cloudflare.com iburst nts" ];
    firewallNoOutputHook = !(lib.hasInfix "hook output" (firewall fencedOn));
    firewallReplies =
      lib.hasInfix "established : accept" (firewall fencedOn)
      && lib.hasInfix "related : accept" (firewall fencedOn);
    fencedFirewallUnchanged = firewall fencedOn == firewall fencedOff;
    fenceUnchanged = fence fencedOn == fence fencedOff;
    fenceNoOutputHook = !(lib.hasInfix "hook output" (fence fencedOn));
    fenceLinkLocalScoped =
      lib.hasInfix ''iifname "driver0" jump routed'' (fence fencedOn)
      && lib.hasInfix ''iifname "conform0" jump routed'' (fence fencedOn)
      && lib.hasInfix "169.254.0.0/16" (fence fencedOn);
  }
  // lib.optionalAttrs (base != "") {
    unchangedBase =
      lib.all
        (
          system:
          flake.checks.${system}.machine.drvPath == (builtins.getFlake ("path:" + toString base))
          .checks.${system}.machine.drvPath
        )
        [
          "x86_64-linux"
          "aarch64-linux"
        ];
  }
  // lib.concatMapAttrs (
    provider: policies:
    lib.concatMapAttrs (
      resolvers: result:
      lib.mapAttrs' (name: value: lib.nameValuePair "${provider}-${resolvers}-${name}" value) result.tests
    ) policies
  ) cases;
in
assert lib.assertMsg (lib.all (v: v) (builtins.attrValues tests))
  "Time evaluation failed for ${
    lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: v: !v) tests))
  }";
{
  inherit tests;
  configurations = lib.mapAttrs (_: lib.mapAttrs (_: result: result.configuration)) cases;
  drvPath = off.system.build.toplevel.drvPath;
}
