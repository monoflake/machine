{
  flake,
  key,
  nixKey,
}:
let
  inherit (flake.inputs.nixpkgs) lib;
  expiry = "20271231Z";
  configured =
    system: nudge: enable:
    (lib.nixosSystem {
      modules = [
        flake.nixosModules.machine
        ../../../template/configuration.nix
        {
          nixpkgs.hostPlatform = system;
          machine.nudge = nudge;
          machine.update = {
            inherit enable;
            bucket = "fixture";
            at = "13:00";
            pointerPublicKey = key;
            nixPublicKey = nixKey;
            credentialsFile = "/run/secrets/systems-credentials";
            endpointFile = "/run/secrets/systems-endpoint";
          };
        }
      ];
    }).config;
  rejected = c: lib.any (a: !a.assertion && lib.hasPrefix "machine.nudge." a.message) c.assertions;
  check =
    system:
    let
      c = configured system { inherit key expiry; } true;
      disabled = configured system { } true;
      off = configured system { } false;
      pkgs = import flake.inputs.nixpkgs { inherit system; };
      package = pkgs.callPackage (flake.outPath + "/system/nix/update/package.nix") { };
      user = c.users.users.nudge;
      rule =
        lib.replaceStrings [ disabled.security.polkit.extraConfig ] [ "" ]
          c.security.polkit.extraConfig;
      keys = user.openssh.authorizedKeys.keys;
      prefix = ''restrict,command="'';
      suffix = ''",expiry-time="${expiry}" ${key}'';
      command = lib.removeSuffix suffix (lib.removePrefix prefix (builtins.head keys));
    in
    assert rejected (configured system { inherit key; } true);
    assert rejected (configured system { inherit expiry; } true);
    assert rejected (configured system { inherit key expiry; } false);
    assert !rejected c;
    # The whole system evaluates, as NixOS checks the account's shell only there.
    assert lib.hasSuffix ".drv" c.system.build.toplevel.drvPath;
    assert !rejected disabled;
    assert !rejected off;
    assert disabled.machine.nudge.key == null;
    assert disabled.machine.nudge.expiry == null;
    assert !(disabled.users.users ? nudge);
    assert !(disabled.users.groups ? nudge);
    assert disabled.security.polkit == off.security.polkit;
    assert !lib.hasInfix "update-now@" disabled.security.polkit.extraConfig;
    assert user.isSystemUser;
    assert !user.isNormalUser;
    assert user.group == "nudge";
    assert c.users.groups ? nudge;
    assert user.hashedPassword == "!";
    assert user.password == null;
    assert user.openssh.authorizedKeys.keyFiles == [ ];
    assert keys == [ (prefix + command + suffix) ];
    assert command == lib.getExe' package "machine-update-nudge";
    assert !(builtins.elem package c.environment.systemPackages);
    assert
      builtins.filter (line: line != "" && !lib.hasPrefix "#!" line) (
        lib.splitString "\n" user.shell.text
      ) == [ "exec ${command}" ];
    assert c.security.polkit.enable;
    assert lib.hasInfix ''subject.user === "nudge"'' rule;
    assert lib.hasInfix ''action.id === "org.freedesktop.systemd1.manage-units"'' rule;
    assert lib.hasInfix ''action.lookup("verb") === "start"'' rule;
    assert lib.hasInfix ''action.lookup("unit") === "update-now@system.service"'' rule;
    assert lib.hasInfix ''action.lookup("unit") === "update-now@driver.service"'' rule;
    assert builtins.length (lib.splitString "update-now@" rule) == 3;
    assert builtins.length (lib.splitString ''lookup("verb")'' rule) == 2;
    assert c.networking.firewall == disabled.networking.firewall;
    assert c.services.openssh.settings == disabled.services.openssh.settings;
    assert c.services.openssh.ports == disabled.services.openssh.ports;
    assert c.services.openssh.openFirewall == disabled.services.openssh.openFirewall;
    assert c.security.sudo == disabled.security.sudo;
    {
      passed = true;
      inherit rule;
    };
in
lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] check
