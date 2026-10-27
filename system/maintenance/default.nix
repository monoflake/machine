# What a person maintaining the machine by hand reaches for, on unless `machine.maintenance` is off.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./fastfetch.nix ];

  config = lib.mkIf config.machine.maintenance.enable {
    environment = {
      systemPackages = with pkgs.unstable; [
        fastfetch-unwrapped
        htop
        eza
        tmux
        ncdu
        jq
        lsof
        strace
        tcpdump
        dnsutils
        iperf3
        # It uploads a trace map to its own service by default, so it runs with `-M` here, and with
        # `-d disable-geoip` where even its geo API should not see the hops.
        nexttrace
        ripgrep
        fd
      ];
      shellAliases = {
        c = "clear";
        os = "fastfetch";
        ls = "eza";
        ll = "eza -la";
        la = "eza -la";
        lt = "eza -T -L 2";
        l = "eza -lah";
        ".." = "cd ..";
        "..." = "cd ../..";
      };
    };
  };
}
