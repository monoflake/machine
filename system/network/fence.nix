# The fence around the driver's containers, monoflake/driver's RFC p95sv; this module writes every
# rule and the driver writes only the elements of `inet fence`'s set `reaching`, docs/fence.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.machine.driver;
  inherit (config.machine) conform;
  # The bridges as bridge.nix names them, the entry's port as driver.nix gives it, and the tailnet.
  named = import ./bridge.nix;
  tailnet = config.services.tailscale.interfaceName;
  entry = lib.toInt (lib.last (lib.splitString ":" cfg.entry));
  inherit (pkgs) buildPackages;
  # Every driver's bridge, the live one and conform's, fenced alike whether conform runs or not.
  bridges = [
    named.live
    named.conform
  ];
  # The rules one bridge is given, written for each, one rule to a line.
  each = rules: lib.concatMapStringsSep "\n    " rules bridges;

  # Fails unless every rule is scoped to a bridge or its ports and every base chain's policy is
  # accept, which holds the fence off the machine's other traffic, docs/fence.md.
  scope = pkgs.writeText "fence-scope.awk" ''
    function fail(why) {
      printf "fence: line %d, %s: %s\n", NR, why, $0 > "/dev/stderr"
      bad = 1
    }

    BEGIN {
      either = bridges
      gsub(/ /, "|", either)
      scoped = "^(iifname|oifname|meta ibrname|meta obrname) \"(" either ")\" "
    }

    {
      sub(/^[ \t]+/, "")
      sub(/[ \t]+$/, "")
    }

    $0 == "" || /^#/ { next }

    depth == 0 && /^flush chain (inet|bridge) fence [a-z]+$/ { next }

    depth == 0 && /^table / {
      if ($0 !~ /^table (inet|bridge) fence \{$/)
        fail("a table not the fence's")
      family = $2
      depth = 1
      next
    }

    depth == 0 { fail("outside the fence's tables"); next }

    depth == 1 && /^set [a-z]+ \{$/ { depth = 2; inset = 1; next }

    depth == 1 && /^chain [a-z]+ \{$/ { chain = family " " $2; depth = 2; next }

    depth == 1 && $0 == "}" { depth = 0; next }

    depth == 1 { fail("neither a set nor a chain"); next }

    inset && $0 == "}" { depth = 1; inset = 0; next }

    inset {
      if ($0 !~ /^type [a-z0-9_ .]+$/)
        fail("a set declaring more than its type")
      next
    }

    $0 == "}" { depth = 1; next }

    /^type / {
      if ($0 !~ /^type filter hook [a-z]+ priority filter; policy accept;$/)
        fail("a base chain not a filter whose policy is accept")
      base[chain] = 1
      next
    }

    /[;\\]/ { fail("more than one rule on a line, or one on more than a line"); next }

    {
      if (chain in base) {
        if ($0 !~ scoped)
          fail("a base chain's rule not scoped to " bridges)
        for (i = 1; i < NF; i++)
          if ($i == "jump" || $i == "goto")
            target[family " " $(i + 1)] = 1
      } else {
        if ($0 ~ /(^| )(jump|goto) /)
          fail("a chain jumping on, beyond the one step the scope is checked for")
        ruled[chain] = NR
      }
    }

    END {
      for (c in ruled)
        if (!(c in target)) {
          printf "fence: chain %s holds rules no scoped rule jumps to\n", c > "/dev/stderr"
          bad = 1
        }
      exit bad
    }
  '';

  # Declared where absent and its chains flushed, so the elements the driver wrote are kept.
  ruleset = pkgs.writeTextFile {
    name = "fence.nft";
    text = ''
      table inet fence {
        set reaching {
          type ipv4_addr . ipv4_addr . inet_service
        }
        chain input {
          type filter hook input priority filter; policy accept;
        }
        chain forward {
          type filter hook forward priority filter; policy accept;
        }
        chain host {
        }
        chain routed {
        }
      }
      table bridge fence {
        chain forward {
          type filter hook forward priority filter; policy accept;
        }
        chain between {
        }
      }
      flush chain inet fence input
      flush chain inet fence forward
      flush chain inet fence host
      flush chain inet fence routed
      flush chain bridge fence forward
      flush chain bridge fence between

      table inet fence {
        chain input {
          ${each (b: ''iifname "${b}" jump host'')}
        }
        # Only a reply is forwarded to a container, never a neighbor routing through the host.
        chain forward {
          ${each (b: ''iifname "${b}" jump routed'')}
          ${each (b: ''oifname "${b}" ct state != { established, related } drop'')}
        }
        # A container reaches the host only where an element names it, or in reply to the host.
        chain host {
          ct state established,related accept
          ip saddr . ip daddr . tcp dport @reaching accept
          drop
        }
        # Never another machine's private network, nor the tailnet by address or by interface.
        chain routed {
          ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 } drop
          ip6 daddr { fc00::/7, fe80::/10 } drop
          oifname "${tailnet}" drop
        }
      }
      table bridge fence {
        chain forward {
          ${each (b: ''meta ibrname "${b}" jump between'')}
        }
        # No frame passes from one container to another but ARP.
        chain between {
          ether type arp accept
          drop
        }
      }
    '';
    # Scoped to the bridges alone, then checked against a kernel of its own as NixOS checks its own.
    checkPhase = ''
      ${buildPackages.gawk}/bin/awk -v 'bridges=${toString bridges}' -f ${scope} $out
      LD_PRELOAD=${buildPackages.lklWithFirewall.lib}/lib/liblkl-hijack.so \
        ${buildPackages.nftables}/bin/nft --check --file $out
    '';
  };
  # The driver, its entry and the entry's socket start only with the fence loaded, and stop with it.
  fenced = {
    requires = [ "fence.service" ];
    after = [ "fence.service" ];
  };
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.networking.nftables.flushRuleset;
        message = "networking.nftables.flushRuleset would flush the fence and the elements the driver wrote.";
      }
    ];

    # Each entry's port open on its own bridge in NixOS's firewall, the fence narrowing it.
    networking.firewall.interfaces = lib.mkMerge [
      { ${named.live}.allowedTCPPorts = [ entry ]; }
      (lib.mkIf conform.enable { ${named.conform}.allowedTCPPorts = [ conform.entry ]; })
    ];

    systemd.services = {
      # Ordered as NixOS's own firewall, nftables.service, is.
      fence = {
        description = "The fence around the driver's containers";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-pre.target"
          "sysinit.target"
        ];
        after = [ "sysinit.target" ];
        before = [
          "network-pre.target"
          "shutdown.target"
        ];
        conflicts = [ "shutdown.target" ];
        unitConfig.DefaultDependencies = false;
        # Applied again rather than stopped when it changes, so the set's elements stay.
        reloadIfChanged = true;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${lib.getExe pkgs.nftables} -f ${ruleset}";
          ExecReload = "${lib.getExe pkgs.nftables} -f ${ruleset}";
        };
      };
      driver-machine = fenced;
      driver-machine-entry = fenced;
    };
    # Nothing accepts a connection on the entry's port without the fence.
    systemd.sockets.driver-machine-entry = fenced;
  };
}
