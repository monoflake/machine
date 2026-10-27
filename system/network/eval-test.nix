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
  renamed = template { services.tailscale.interfaceName = "tailnet-test"; };
  relay = template { machine.tailnet.relayPort = 40000; };
  exit = template { machine.tailnet.exitNode = true; };
  connector = template { machine.tailnet.connector = true; };
  driver = template {
    machine.driver = {
      enable = true;
      override = "/var/lib/driver-machine/dev/driver-machine";
    };
  };
  configurations = [
    defaults
    routed
    subnet
    open
    renamed
    relay
    connector
    driver
  ];
  tailnetFirewall =
    cfg:
    let
      firewall = cfg.networking.firewall;
      interface = cfg.services.tailscale.interfaceName;
    in
    !(lib.elem interface firewall.trustedInterfaces)
    && firewall.interfaces.${interface}.allowedTCPPorts == [ 22 ]
    && firewall.interfaces.${interface}.allowedTCPPortRanges == [ ]
    && firewall.allowedTCPPorts == [ 22 ]
    && firewall.allowedTCPPortRanges == [ ];
  driverClosed =
    cfg:
    lib.all (
      interface:
      !(lib.elem 37483 interface.allowedTCPPorts)
      && lib.all (range: 37483 < range.from || 37483 > range.to) interface.allowedTCPPortRanges
    ) (builtins.attrValues cfg.networking.firewall.allInterfaces);
  accepted = value: (import ./cidr.nix { inherit lib; }) value;
  refusedBy = infix: lib.any (a: !a.assertion && lib.hasInfix infix a.message);
  refused = refusedBy "--accept-routes";
  conflicting = refusedBy "machine.tailnet.connector";
  assertionsFor = extra: (template extra).assertions;
  rules = import ./ssh/input.nix {
    inherit (defaults.services.tailscale) interfaceName;
  };
  script = import ./ssh/close.nix;
  service = defaults.systemd.services.machine-ssh-close;
  unit = defaults.systemd.units."nftables.service".text;
  # The closer must preserve SSH on the configured tailnet interface.
  sshInterface =
    cfg:
    let
      expected = ''
        table inet machine-ssh {
        	chain input {
        		type filter hook input priority filter - 10; policy accept;
        		tcp dport 22 iifname != { "${cfg.services.tailscale.interfaceName}", "lo" } drop
        	}
        }
      '';
      file = flake.inputs.nixpkgs.legacyPackages.x86_64-linux.writeText "machine-ssh.nft" expected;
    in
    lib.hasSuffix (toString file) cfg.systemd.services.machine-ssh-close.serviceConfig.ExecStart;
  tests = {
    defaultRoutes = defaults.services.tailscale.extraSetFlags == [ "--accept-dns=false" ];
    subnetRoutes =
      subnet.services.tailscale.extraSetFlags == [
        "--accept-dns=false"
        "--advertise-routes=192.0.2.0/24"
      ];
    exitOnly =
      exit.services.tailscale.extraSetFlags == [
        "--accept-dns=false"
        "--advertise-exit-node"
        "--stateful-filtering=true"
      ];
    connectorFlags =
      connector.services.tailscale.extraSetFlags == [
        "--accept-dns=false"
        "--advertise-connector"
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
      && exit.services.tailscale.useRoutingFeatures == "server"
      && connector.services.tailscale.useRoutingFeatures == "server";
    connectorAlone = !(conflicting connector.assertions);
    connectorExitRefused = conflicting (assertionsFor {
      machine.tailnet = {
        connector = true;
        exitNode = true;
      };
    });
    connectorRoutesRefused = conflicting (assertionsFor {
      machine.tailnet = {
        connector = true;
        routes = [ "198.51.100.7/32" ];
      };
    });
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
    tailnetInput = lib.all tailnetFirewall configurations;
    driverInput = lib.all driverClosed configurations;
    tailnetPing = lib.all (cfg: cfg.networking.firewall.allowPing) configurations;
    exitForwarding =
      !routed.networking.firewall.filterForward
      && routed.boot.kernel.sysctl."net.ipv4.conf.all.forwarding" == true
      && routed.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" == true;
    relayInput =
      lib.elem relay.machine.tailnet.relayPort relay.networking.firewall.allowedUDPPorts
      && lib.elem relay.services.tailscale.port relay.networking.firewall.allowedUDPPorts;
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
    defaultSshInterface = sshInterface defaults;
    renamedSshInterface = sshInterface renamed;
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
