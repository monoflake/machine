# The message a move of the flake's inputs is committed with, naming each held package it changed.
# The subject and the body keep the workspace's widths, and what does not fit is counted.
{
  lib,
  old,
  new,
  moved,
}:
let
  width = 96;
  lines = 5;
  first = [
    "linux"
    "systemd"
    "nix"
    "containerd"
    "tailscale"
    "openssh"
  ];
  rank =
    name:
    let
      found = lib.lists.findFirstIndex (other: other == name) null first;
    in
    if found == null then builtins.length first else found;
  before = a: b: if rank a != rank b then rank a < rank b else a < b;
  version = set: name: set.${name} or "none";
  names = lib.sort before (
    builtins.filter (name: version old name != version new name) (
      lib.unique (builtins.attrNames old ++ builtins.attrNames new)
    )
  );
  count = builtins.length names;
  shown = lib.removeSuffix "-unwrapped";
  more = rest: "and ${toString rest} more";

  listed =
    words:
    if builtins.length words < 2 then
      lib.concatStrings words
    else
      "${lib.concatStringsSep ", " (lib.init words)} and ${lib.last words}";
  subject =
    taken:
    let
      rest = count - taken;
      heads = map (name: "${shown name} ${version new name}") (lib.take taken names);
    in
    "build: update "
    + (
      if taken == 0 then
        "${toString rest} packages"
      else if rest == 0 then
        listed heads
      else
        "${lib.concatStringsSep ", " heads} ${more rest}"
    );
  downward = lib.reverseList (lib.range 0 count);
  fitted = lib.findFirst (taken: lib.stringLength (subject taken) <= width) 0 downward;

  # Each word joins the line before it by its own separator, or opens a line where it would not fit.
  pack = lib.foldl' (
    packed: word:
    let
      joined = "${lib.last packed}${word.separator}${word.text}";
    in
    if packed == [ ] then
      [ word.text ]
    else if lib.stringLength joined <= width then
      lib.init packed ++ [ joined ]
    else
      packed ++ [ word.text ]
  ) [ ];
  body =
    taken:
    pack (
      map (name: {
        separator = ", ";
        text = "${shown name} ${version old name} -> ${version new name}";
      }) (lib.take taken names)
      ++ lib.optional (taken < count) {
        separator = " ";
        text = more (count - taken);
      }
    );
  fittedBody = lib.findFirst (packed: builtins.length packed <= lines) [ ] (map body downward);
in
if count == 0 then
  "build: update ${listed moved}, no package a machine holds changed\n"
else
  "${subject fitted}\n\n${lib.concatStringsSep "\n" fittedBody}\n"
