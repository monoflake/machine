{ lib }:
{
  machines,
  defaults,
  builds ? 1900,
  self ? 4096,
  gap ? 20,
  flake ? null,
}:
let
  fail = n: message: throw "fleet ${n}: ${message}";
  inventory = lib.mapAttrs (
    n: m:
    if !builtins.isAttrs m then
      fail n "machine must be an attribute set"
    else if builtins.match "[a-zA-Z0-9_][a-zA-Z0-9_-]*" n == null then
      fail n "invalid name"
    else if !(m ? system && m ? memory && m ? at) then
      fail n "system, memory and at are required"
    else if !builtins.isBool (m.planned or false) then
      fail n "planned must be boolean"
    else if !builtins.isBool (m.build or true) then
      fail n "build must be boolean"
    else if !builtins.isInt m.memory then
      fail n "memory must be integer MB"
    else
      m
  ) machines;
  active = lib.filterAttrs (_: m: !(m.planned or false)) inventory;
  names = builtins.attrNames active;
  builder = m: m.memory >= builds && (m.build or true);
  own = m: builder m && m.memory > self;
  number = s: lib.toInt (if lib.hasPrefix "0" s then builtins.substring 1 1 s else s);
  minutes =
    n: at:
    if builtins.isString at && builtins.match "([01][0-9]|2[0-3]):[0-5][0-9]" at != null then
      number (builtins.substring 0 2 at) * 60 + number (builtins.substring 3 2 at)
    else
      fail n "at must be HH:MM in UTC";
  wrap = t: t - builtins.floor (t / 1440.0) * 1440;
  time =
    raw:
    let
      t = wrap raw;
      pad = v: lib.fixedWidthString 2 "0" (toString v);
    in
    "${pad (builtins.div t 60)}:${pad (t - builtins.div t 60 * 60)}";
  sets = lib.mapAttrs (
    n: m:
    let
      requested = m.builders or (defaults.${m.system} or { });
      valid = lib.mapAttrs (
        b: priority:
        if !(builtins.isInt priority && priority >= 1 && priority <= 3) then
          fail n "builder ${b} priority must be an integer from 1 to 3"
        else if !(builtins.hasAttr b inventory) then
          fail n "unknown builder ${b}"
        else if inventory.${b}.planned or false then
          priority
        else if !builder inventory.${b} && m ? builders then
          fail n "${b} is not a builder"
        else if inventory.${b}.system != m.system then
          fail n "${b} has another architecture"
        else
          priority
      ) (if builtins.isAttrs requested then requested else fail n "builders must be an attribute set");
    in
    builtins.deepSeq valid (
      lib.filterAttrs (b: _: !own m && b != n && builtins.hasAttr b active && builder active.${b}) valid
    )
  ) active;
  layouts = lib.mapAttrs (
    n: m:
    let
      count = builtins.length (builtins.attrNames sets.${n});
      end = minutes n m.at;
      start = end - (count + 1) * gap;
    in
    if !(builtins.isInt gap && gap > 0) then
      fail n "gap must be positive minutes"
    else if !builder m && count == 0 then
      fail n "consumer has no builders"
    else if (count + 1) * gap >= 1440 then
      fail n "slots do not fit before at"
    else
      lib.genList (k: time (start + k * gap)) count
  ) active;
  offsets = lib.mapAttrs (
    n: m:
    let
      count = builtins.length layouts.${n};
      start = minutes n m.at - (count + 1) * gap;
    in
    lib.genList (k: builtins.floor ((start + k * gap) / 1440.0)) count
  ) active;
  collisions = lib.mapAttrs (
    b: _:
    let
      entries = lib.concatMap (
        n:
        if builtins.hasAttr b sets.${n} then
          map (at: {
            machine = n;
            minute = minutes n at;
          }) layouts.${n}
        else
          [ ]
      ) names;
      sorted = builtins.sort (a: c: a.minute < c.minute) entries;
      count = builtins.length sorted;
      pairs = lib.genList (
        k:
        let
          a = builtins.elemAt sorted k;
          c = builtins.elemAt sorted (if k + 1 == count then 0 else k + 1);
          distance = c.minute - a.minute + (if k + 1 == count then 1440 else 0);
        in
        if count > 1 && distance < gap then
          fail b "slots for ${a.machine} and ${c.machine} are closer than one gap"
        else
          true
      ) count;
    in
    builtins.deepSeq pairs true
  ) (lib.filterAttrs (_: builder) active);
  checked = lib.mapAttrs (
    n: m:
    if
      !(builtins.elem m.system [
        "x86_64-linux"
        "aarch64-linux"
      ])
    then
      fail n "unsupported system"
    else if !(builtins.isInt m.memory && m.memory > 0) then
      fail n "memory must be positive MB"
    else if !(builtins.isString (m.flake or flake)) || (m.flake or flake) == "" then
      fail n "flake is required"
    else if builtins.hasAttr "build" m && !builtins.isBool m.build then
      fail n "build must be boolean"
    else if
      builder m
      && !(
        m ? keys
        && builtins.isAttrs m.keys
        && lib.all (k: builtins.isString (m.keys.${k} or null)) [
          "pointer"
          "nix"
          "access"
        ]
      )
    then
      fail n "builder needs pointer, nix and access public keys"
    else
      builtins.deepSeq (minutes n m.at) m
  ) active;
  result = lib.mapAttrs (n: m: {
    role = if builder m then (if own m then "builder" else "both") else "fetched";
    builders = sets.${n};
    slots = layouts.${n};
    order =
      date:
      builtins.sort (
        a: b:
        if sets.${n}.${a} != sets.${n}.${b} then
          sets.${n}.${a} < sets.${n}.${b}
        else
          builtins.hashString "sha256" "${n}:${date}:${a}" < builtins.hashString "sha256" "${n}:${date}:${b}"
      ) (builtins.attrNames sets.${n});
    schedule =
      date:
      lib.imap0 (k: b: {
        builder = b;
        at = builtins.elemAt layouts.${n} k;
        dayOffset = builtins.elemAt offsets.${n} k;
      }) (result.${n}.order date);
    machine.upgrade.at = m.at;
    machine.cache = {
      inventory = {
        name = n;
        inherit (m) at;
        builders = builtins.attrNames sets.${n};
      };
      builds = lib.genAttrs (builtins.filter (c: builtins.hasAttr n sets.${c}) names) (c: {
        flake = active.${c}.flake or flake;
        host = active.${c}.host or c;
        at = builtins.head layouts.${c};
        slots = layouts.${c};
        slotDays = offsets.${c};
        builders = sets.${c};
        inherit gap;
      });
      fetch.builders = map (
        b:
        if !(active.${b} ? keys) then
          fail n "builder ${b} needs public keys"
        else
          {
            inherit (active.${b}.keys) pointer nix access;
            name = b;
          }
      ) (builtins.attrNames sets.${n});
      builder.self = if builder m then (if own m then "build" else "cache") else null;
    };
  }) checked;
in
builtins.deepSeq inventory (
  builtins.deepSeq checked (
    builtins.deepSeq sets (
      builtins.deepSeq layouts (builtins.deepSeq collisions (builtins.deepSeq result result))
    )
  )
)
