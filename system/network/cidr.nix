# A CIDR has an address and a bounded prefix length in either family.
{ lib }:
let
  decimal = s: builtins.match "(0|[1-9][0-9]{0,2})" s != null;
  ipv4 =
    s:
    let
      octets = lib.splitString "." s;
    in
    builtins.length octets == 4 && lib.all (o: decimal o && lib.toInt o <= 255) octets;
  ipv6 =
    s:
    let
      halves = lib.splitString "::" s;
      groups = lib.concatMap (h: if h == "" then [ ] else lib.splitString ":" h) halves;
      dotted = groups != [ ] && ipv4 (lib.last groups) && lib.hasSuffix (lib.last groups) s;
      hex = if dotted then lib.init groups else groups;
      size = builtins.length hex + (if dotted then 2 else 0);
    in
    lib.all (h: builtins.match "[0-9a-fA-F]{1,4}" h != null) hex
    && (if builtins.length halves == 2 then size < 8 else builtins.length halves == 1 && size == 8);
in
s:
let
  parts = lib.splitString "/" s;
  address = builtins.head parts;
  prefix = lib.last parts;
in
builtins.length parts == 2
&& decimal prefix
&& (
  (ipv4 address && lib.toInt prefix <= 32)
  || (lib.hasInfix ":" address && ipv6 address && lib.toInt prefix <= 128)
)
