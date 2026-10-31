# A console on the serial line and the screen, a PC's first UART or an Arm machine's PL011.
{ pkgs, ... }:
let
  serial = if pkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0";
in
{
  boot.kernelParams = [
    "console=${serial},115200n8"
    "console=tty0"
  ];
}
