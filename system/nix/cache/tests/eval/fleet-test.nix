{ lib }:
let
  fleet = import ../../fleet.nix { inherit lib; };
  example = import ../fixtures/fleet-example.nix;
  result = fleet example;
  patch =
    n: attrs:
    example
    // {
      machines = example.machines // {
        ${n} = example.machines.${n} // attrs;
      };
    };
  refuses = args: !(builtins.tryEval (builtins.deepSeq (fleet args) true)).success;
  low = fleet (patch "a2" { memory = 1899; });
  at = fleet (patch "a2" { memory = 1900; });
  above = fleet (patch "a2" { memory = 1901; });
  under = fleet (patch "a1" { memory = 4095; });
  over = fleet (patch "a1" { memory = 4097; });
  midnight = fleet (patch "c1" { at = "00:30"; });
  equal = fleet (
    patch "c1" {
      builders = {
        a1 = 1;
        a2 = 1;
      };
    }
  );
  planned = fleet (
    example
    // {
      defaults = example.defaults // {
        aarch64-linux = example.defaults.aarch64-linux // {
          b5 = 1;
        };
      };
    }
  );
  tests = [
    (low.a2.role == "fetched" && at.a2.role == "both" && above.a2.role == "both")
    (
      equal.c1.order "2026-10-26" == [
        "a1"
        "a2"
      ]
    )
    (
      equal.c1.order "2026-10-28" == [
        "a2"
        "a1"
      ]
    )
    (
      equal.c1.slots == [
        "07:00"
        "07:20"
      ]
    )
    (
      result.c1.slots == [
        "06:40"
        "07:00"
        "07:20"
      ]
    )
    (
      midnight.c1.slots == [
        "23:10"
        "23:30"
        "23:50"
      ]
    )
    (
      (map (s: s.dayOffset) (midnight.c1.schedule "2026-10-27")) == [
        (-1)
        (-1)
        (-1)
      ]
    )
    (result.c1.machine.upgrade.at == "08:00")
    (result.c1.machine.cache.inventory.at == "08:00")
    (
      result.a1.machine.cache.builds.a2.builders == {
        a1 = 1;
        a3 = 3;
      }
    )
    (!(builtins.hasAttr "a1" result.a1.machine.cache.builds))
    (!(builtins.hasAttr "c1" (fleet (patch "c1" { planned = true; })).a1.machine.cache.builds))
    ((fleet (patch "b1" { build = false; })).b1.role == "fetched")
    (
      result.c1.order "2026-10-26" == [
        "a1"
        "a2"
        "a3"
      ]
    )
    (builtins.length result.c4.slots == 4)
    (builtins.length (lib.unique (map (s: s.at) (result.c4.schedule "2026-10-26"))) == 4)
    (result.c4.order "2026-10-26" != result.c4.order "2026-10-27")
    (builtins.elemAt (result.c4.order "2026-10-26") 3 == "b4")
    (result.a1.role == "both" && under.a1.role == "both" && over.a1.role == "builder")
    ((fleet (patch "a1" { build = false; })).a1.role == "fetched")
    (
      result.a1.builders == {
        a2 = 2;
        a3 = 3;
      }
    )
    (over.a1.builders == { } && over.a1.slots == [ ])
    (result.a3.machine.cache.builder.self == "build")
    (result.a1.machine.cache.builder.self == "cache")
    (!(builtins.hasAttr "b5" planned) && !(builtins.hasAttr "b5" planned.c4.builders))
    (refuses (patch "c2" { at = "08:10"; }))
    (refuses (example // { gap = 500; }))
    (refuses (builtins.removeAttrs example [ "flake" ]))
    (refuses (patch "c1" { builders.b1 = 1; }))
    (refuses (patch "c1" { builders.c2 = 1; }))
    (refuses (patch "c1" { at = "25:00"; }))
  ]
  ++ map (priority: refuses (patch "c1" { builders.a1 = priority; })) [
    0
    4
    1.5
    "1"
  ];
in
assert lib.all (v: v) tests;
{
  passed = builtins.length tests;
  orders =
    lib.concatMap
      (
        name:
        map
          (date: {
            inherit name date;
            builders = result.${name}.builders;
            order = result.${name}.order date;
          })
          [
            "2026-10-26"
            "2026-10-27"
            "2026-10-28"
            "2026-10-29"
          ]
      )
      [
        "c1"
        "c2"
        "c4"
        "c6"
      ];
}
