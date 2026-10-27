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
      cacheServices =
        map
          (
            c:
            lib.filterAttrs (
              name: _:
              lib.hasPrefix "machine-cache-" name
              # An idempotent preparation that holds no run, in system/nix/cache/store.nix.
              && name != "machine-cache-build-store"
            ) c.systemd.services
          )
          [
            small
            large
            consumer
            badAt
            badHost
            badNames
            repeated
            missing
            data
            dataLarge
            badStore
            outsideRun
            noData
          ];
      cacheNames = lib.concatMap builtins.attrNames cacheServices;
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
      data = configured system "a1" { machine.cache.builder.data = true; };
      dataLarge = configured system "a3" { machine.cache.builder.data = true; };
      selfRun = lib.findFirst (
        p: p.name or "" == "machine-cache-run"
      ) null dataLarge.environment.systemPackages;
      badStore = configured system "a1" {
        machine.cache.builder.data = true;
        machine.cache.builder.store = "local?root=/var/tmp/build";
      };
      outsideRun = configured system "a3" {
        machine.cache.builder.data = true;
        machine.cache.builder.self = lib.mkForce null;
      };
      noData = configured system "a1" {
        machine.cache.builder.data = true;
        fileSystems = lib.mkForce { };
      };
      dataServices = map (name: data.systemd.services.${name}) [
        "machine-cache-c1"
        "machine-cache-now@c1"
        "machine-cache-self"
      ];
      storage = data.systemd.services.machine-cache-build-store;
      calendars = small.systemd.timers.machine-cache-c1.timerConfig.OnCalendar;
    in
    assert lib.all rejected [
      badAt
      badHost
      badNames
      repeated
      missing
    ];
    assert !small.machine.cache.builder.data;
    assert small.machine.cache.builder.store == null;
    assert !(small.systemd.services ? machine-cache-build-store);
    assert data.machine.cache.builder.store == "local?root=/data/build/root";
    assert dataLarge.machine.cache.builder.store == "local?root=/data/build/root";
    assert dataLarge.systemd.services.machine-cache-self.environment.TMPDIR == "/data/build/tmp";
    assert lib.hasInfix ''evaluate=(--eval-store "$store")'' run.text;
    assert !lib.hasInfix "on=(--store local)" run.text;
    assert
      dataLarge.systemd.services.machine-cache-self.serviceConfig.ExecStart
      == "${lib.getExe selfRun} a3 --self";
    assert lib.hasInfix ''activate=(--option substituters "$store&trusted=true")'' selfRun.text;
    assert lib.hasInfix ''nix-env "''${activate[@]}" -p /nix/var/nix/profiles/system --set''
      selfRun.text;
    assert !lib.hasInfix "--to local" selfRun.text;
    assert !lib.hasInfix "--no-check-sigs" selfRun.text;
    assert !lib.hasInfix "require-sigs" selfRun.text;
    assert data.nix.settings.require-sigs or true;
    assert
      !lib.any (lib.hasInfix "/data/build") (
        data.nix.settings.substituters or [ ] ++ data.nix.settings.trusted-substituters or [ ]
      );
    assert lib.any (
      a: !a.assertion && lib.hasInfix "needs machine.cache.builder.store" a.message
    ) badStore.assertions;
    assert lib.any (
      a: !a.assertion && lib.hasInfix "needs machine.cache.builder.self" a.message
    ) outsideRun.assertions;
    assert data.nix.settings.build-dir == "/data/build/builds";
    assert lib.all (
      s:
      s.environment.TMPDIR == "/data/build/tmp"
      && s.environment.XDG_CACHE_HOME == "/data/build/cache"
      && s.environment.NIX_LOG_DIR == "/data/build/log"
      && builtins.elem "/data" s.unitConfig.RequiresMountsFor
      && builtins.elem "machine-cache-build-store.service" s.requires
      && builtins.elem "machine-cache-build-store.service" s.after
    ) dataServices;
    assert data.systemd.services.nix-daemon.environment.TMPDIR == "/data/build/daemon-tmp";
    assert data.systemd.services.nix-daemon.environment.XDG_CACHE_HOME == "/data/build/cache";
    assert data.systemd.services.nix-daemon.environment.NIX_LOG_DIR == "/data/build/log";
    assert builtins.elem "/data" data.systemd.services.nix-daemon.unitConfig.RequiresMountsFor;
    assert builtins.elem "machine-cache-build-store.service" data.systemd.services.nix-daemon.requires;
    assert builtins.elem "machine-cache-build-store.service" data.systemd.services.nix-daemon.after;
    assert storage.serviceConfig.Type == "oneshot";
    assert !(storage.serviceConfig.RemainAfterExit or false);
    assert builtins.elem "/data" storage.unitConfig.RequiresMountsFor;
    assert lib.hasInfix "btrfs qgroup limit 10000000000 /data/build" storage.script;
    assert !lib.hasInfix "quota enable" storage.script;
    assert lib.any (a: !a.assertion && lib.hasInfix "needs /data" a.message) noData.assertions;
    assert !small.system.autoUpgrade.enable;
    assert !large.system.autoUpgrade.enable;
    assert large.machine.cache.builder.cap == 5000000000;
    assert large.machine.cache.builder.upstream == "https://cache.nixos.org";
    assert lib.all (c: c.nix.settings.narinfo-cache-positive-ttl == 3600) [
      small
      large
      consumer
    ];
    assert lib.all (c: c.nix.settings.narinfo-cache-negative-ttl == 60) [
      small
      large
      consumer
    ];
    assert lib.hasInfix "rclone copy --no-check-dest" run.text;
    assert lib.hasInfix "rclone size --fast-list" run.text;
    assert
      !lib.any (verb: lib.hasInfix "rclone ${verb}" run.text) [
        "lsjson"
        "lsf"
      ];
    assert small.systemd.services.machine-cache-self.serviceConfig.ExecStart != "";
    assert !(small.systemd.timers ? machine-cache-fetch);
    assert small.systemd.services.machine-cache-fetch.serviceConfig.ExecStart != "";
    assert lib.any (
      name:
      !lib.hasPrefix "machine-cache-now@" name
      && name != "machine-cache-self"
      && name != "machine-cache-fetch"
      && builtins.hasAttr name small.systemd.timers
    ) cacheNames;
    assert lib.any (lib.hasPrefix "machine-cache-now@") cacheNames;
    assert builtins.elem "machine-cache-self" cacheNames;
    assert builtins.elem "machine-cache-fetch" cacheNames;
    assert lib.all (
      services:
      services != { }
      && lib.all (s: s.restartIfChanged == false && s.unitConfig.X-StopOnRemoval == false) (
        builtins.attrValues services
      )
    ) cacheServices;
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
      storage = storage.script;
    };
in
lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] check
