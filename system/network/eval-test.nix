# The template evaluated with documentation routes and both resolver policies.
{
  root ? ../..,
}:
let
  flake = builtins.getFlake ("path:" + toString root);
  inherit (flake.inputs.nixpkgs) lib;
  template =
    extra:
    (lib.nixosSystem {
      modules = [
        flake.nixosModules.machine
        (root + /system/template/configuration.nix)
        { nixpkgs.hostPlatform = "x86_64-linux"; }
        extra
      ];
    }).config;
  defaults = template { };
  routed = template {
    machine.tailnet = {
      routes = [
        "198.51.100.7/32"
        "2001:db8::/32"
      ];
      exitNode = true;
    };
  };
  subnet = template { machine.tailnet.routes = [ "192.0.2.0/24" ]; };
  china = template { machine.network.resolvers = "china"; };
  open = template { machine.ssh.public = "open"; };
  accepted = value: (import ./cidr.nix { inherit lib; }) value;
  refused = flags: lib.any (a: !a.assertion && lib.hasInfix "--accept-routes" a.message) flags;
  assertionsFor = extra: (template extra).assertions;
  rules = import ./ssh/input.nix;
  script = import ./ssh/close.nix;
  service = defaults.systemd.services.machine-ssh-close;
  unit = defaults.systemd.units."nftables.service".text;
  tests = {
    defaultRoutes =
      defaults.services.tailscale.extraSetFlags == [
        "--accept-dns=false"
        "--advertise-routes="
      ];
    exitRoutes =
      routed.services.tailscale.extraSetFlags == [
        "--accept-dns=false"
        "--advertise-routes=198.51.100.7/32,2001:db8::/32"
        "--advertise-exit-node"
        "--stateful-filtering=true"
      ];
    routing =
      routed.services.tailscale.useRoutingFeatures == "server"
      && subnet.services.tailscale.useRoutingFeatures == "server"
      && defaults.services.tailscale.useRoutingFeatures == "none"
      &&
        (template { machine.tailnet.exitNode = true; }).services.tailscale.useRoutingFeatures == "server";
    setRefused = refused (assertionsFor {
      services.tailscale.extraSetFlags = [ "--accept-routes" ];
    });
    upRefused = refused (assertionsFor {
      services.tailscale.extraUpFlags = [ "--accept-routes=true" ];
    });
    aliasRefused = refused (assertionsFor {
      services.tailscale.extraSetFlags = [ "--accept-routes=1" ];
    });
    falseAllowed =
      !(refused (assertionsFor {
        services.tailscale = {
          extraSetFlags = [ "--accept-routes=false" ];
          extraUpFlags = [ "--accept-routes=false" ];
        };
      }));
    validCidrs = lib.all accepted [
      "192.0.2.0/24"
      "198.51.100.7/32"
      "2001:db8::/32"
      "2001:db8:0:0:0:0:0:1/128"
      "2001:db8::192.0.2.1/128"
    ];
    invalidCidrs = lib.all (s: !accepted s) [
      "192.0.2.1"
      "192.0.2.1/33"
      "192.0.2.256/24"
      "192.0.2.01/24"
      "192.0.2.1/-1"
      "192.0.2.1/24/24"
      "2001:db8::/129"
      "2001:db8:::1/64"
      "2001:db8::1::1/64"
      "2001:db8:1/64"
      "2001:db8:0:0:0:0:0:0:1/64"
      "2001:db8::gg/64"
      "2001:db8::/"
      "2001:db8:192.0.2.1::/64"
    ];
    cidrType =
      !(builtins.tryEval (
        builtins.deepSeq (template { machine.tailnet.routes = [ "192.0.2.1/33" ]; }).machine.tailnet.routes
          true
      )).success;
    globalResolvers =
      defaults.networking.nameservers == [
        "1.1.1.1"
        "8.8.8.8"
      ];
    chinaResolvers =
      china.networking.nameservers == [
        "223.5.5.5"
        "223.6.6.6"
      ];
    plainResolvers =
      !defaults.services.resolved.enable
      && !china.services.resolved.enable
      && defaults.networking.resolvconf.enable
      && china.networking.resolvconf.enable
      && !(defaults.environment.etc ? "resolv.conf")
      && !(china.environment.etc ? "resolv.conf");
    firewall =
      defaults.services.openssh.openFirewall
      && open.services.openssh.openFirewall
      && lib.elem 22 defaults.networking.firewall.allowedTCPPorts;
    repair =
      !(builtins.hasAttr "machine-ssh-close" open.systemd.services)
      && !(builtins.hasAttr "machine-ssh-close" open.systemd.timers);
    ordering =
      lib.elem "nftables.service" service.after
      && lib.hasInfix "--no-block restart machine-ssh-close.service" unit
      && lib.hasSuffix "--no-block restart machine-ssh-close.service" (
        lib.last defaults.systemd.services.nftables.serviceConfig.ExecReload
      )
      && lib.hasSuffix "--no-block restart machine-ssh-close.service" (
        lib.last defaults.systemd.services.nftables.serviceConfig.ExecStartPost
      );
    timer = defaults.systemd.timers.machine-ssh-close.timerConfig.OnCalendar == "*-*-* *:*:00";
    renderedRules = lib.hasSuffix (toString (flake.inputs.nixpkgs.legacyPackages.x86_64-linux.writeText "machine-ssh.nft" rules)) service.serviceConfig.ExecStart;
    cleanup = lib.hasInfix "delete table inet machine-ssh" open.networking.nftables.extraDeletions;
  };
in
assert lib.assertMsg (lib.all (v: v) (builtins.attrValues tests))
  "Network evaluation failed for ${
    lib.concatStringsSep ", " (builtins.attrNames (lib.filterAttrs (_: v: !v) tests))
  }";
{
  inherit tests rules script;
}
