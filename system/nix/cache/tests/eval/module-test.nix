{ flake }:
let
  inherit (flake.inputs.nixpkgs) lib;
  example = import ../fixtures/fleet-example.nix;
  fleet = flake.lib.fleet example;
  configured =
    system: name: extra:
    (lib.nixosSystem {
      modules = [
        flake.nixosModules.machine
        ../../../../template/configuration.nix
        {
          nixpkgs.hostPlatform = system;
          networking.hostName = lib.mkOverride 60 name;
          machine = lib.mkMerge [
            fleet.${name}.machine
            {
              upgrade = {
                inherit (example) flake;
              };
              cache = {
                enable = true;
                bucket = "/var/lib/machine-cache-bucket";
                builder = {
                  signingKey = "/var/lib/secrets/nix-key";
                  pointerKey = "/var/lib/secrets/pointer-key";
                  accessKey = "/var/lib/secrets/access-key";
                };
              };
            }
          ];
        }
      ]
      ++ [ extra ];
    }).config;
  machine = system: name: configured system name { };
  check =
    system:
    let
      small = machine system "a1";
      large = machine system "a3";
      consumer = machine system "c1";
      run = lib.findFirst (p: p.name or "" == "machine-cache-run") null small.environment.systemPackages;
      badAt = configured system "c1" { machine.upgrade.at = lib.mkForce "09:00"; };
      badHost = configured system "a1" { networking.hostName = lib.mkForce "a9"; };
      badNames = configured system "c1" {
        machine.cache.fetch.builders = lib.mkForce [ (example.machines.a1.keys // { name = "a9"; }) ];
      };
      repeated = configured system "c1" {
        machine.cache.inventory = lib.mkForce null;
        machine.cache.fetch.builders = lib.mkForce (
          map (_: example.machines.a1.keys // { name = "a1"; }) [
            1
            2
          ]
        );
      };
      missing = configured system "c1" {
        machine.cache.inventory = lib.mkForce null;
        machine.cache.fetch.builders = lib.mkForce [
          example.machines.a1.keys
          example.machines.a2.keys
        ];
      };
      rejected = c: lib.any (a: !a.assertion && lib.hasInfix "machine " a.message) c.assertions;
      calendars = small.systemd.timers.machine-cache-c1.timerConfig.OnCalendar;
    in
    assert lib.all rejected [
      badAt
      badHost
      badNames
      repeated
      missing
    ];
    assert !small.system.autoUpgrade.enable;
    assert !large.system.autoUpgrade.enable;
    assert small.systemd.services.machine-cache-self.serviceConfig.ExecStart != "";
    assert !(small.systemd.timers ? machine-cache-fetch);
    assert small.systemd.services.machine-cache-fetch.serviceConfig.ExecStart != "";
    assert calendars == map (at: "*-*-* ${at}:00 UTC") fleet.c1.slots;
    assert consumer.machine.upgrade.at == example.machines.c1.at;
    assert (builtins.head consumer.machine.cache.fetch.builders).name == small.networking.hostName;
    assert !rejected small;
    assert lib.hasSuffix " c1 --now"
      small.systemd.services."machine-cache-now@c1".serviceConfig.ExecStart;
    assert !(small.systemd.timers ? "machine-cache-now@c1");
    assert large.machine.cache.fetch.builders == [ ];
    {
      passed = true;
      script = run.text;
    };
in
lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] check
