# A machine's TCP, BBR over fq and one cap on every socket buffer, docs/network.md.
{ config, ... }:
let
  cap = config.machine.network.buffer;
in
{
  boot.kernelModules = [ "tcp_bbr" ];
  boot.kernel.sysctl = {
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.rmem_max" = cap;
    "net.core.wmem_max" = cap;
    "net.ipv4.tcp_rmem" = "4096 131072 ${toString cap}";
    "net.ipv4.tcp_wmem" = "4096 16384 ${toString cap}";
  };
}
