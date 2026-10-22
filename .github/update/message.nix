# The message a move of the flake's inputs is committed with, naming what it changed by version.
# Each set takes a name to its versions, and the subject and the body keep the workspace's widths.
{
  lib,
  moved,
  held,
  beneath,
  rebuilt,
  patched,
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
  # The versions of name in one set and not the other, as they are written.
  only =
    set: other: name:
    let
      versions = lib.subtractLists (other.${name} or [ ]) (set.${name} or [ ]);
    in
    if versions == [ ] then "none" else lib.concatStringsSep ", " versions;
  changed =
    sets:
    lib.sort before (
      builtins.filter (name: sets.old.${name} or [ ] != sets.new.${name} or [ ]) (
        lib.unique (builtins.attrNames sets.old ++ builtins.attrNames sets.new)
      )
    );
  shown = lib.removeSuffix "-unwrapped";
  more = rest: "and ${toString rest} more";
  downward = count: lib.reverseList (lib.range 0 count);

  listed =
    words:
    if builtins.length words < 2 then
      lib.concatStrings words
    else
      "${lib.concatStringsSep ", " (lib.init words)} and ${lib.last words}";

  # The subject naming as many of names as fit after prefix, the rest counted.
  subject =
    sets: names: prefix:
    let
      count = builtins.length names;
      line =
        taken:
        let
          rest = count - taken;
          heads = map (name: "${shown name} ${only sets.new sets.old name}") (lib.take taken names);
        in
        "build: update ${prefix}"
        + (
          if taken == 0 then
            "${toString rest} packages"
          else if rest == 0 then
            listed heads
          else
            "${lib.concatStringsSep ", " heads} ${more rest}"
        );
    in
    lib.findFirst (text: lib.stringLength text <= width) (line 0) (map line (downward count));

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
  fill =
    room: words:
    let
      count = builtins.length words;
      packed =
        taken:
        pack (
          lib.take taken words
          ++ lib.optional (taken < count) {
            separator = " ";
            text = more (count - taken);
          }
        );
    in
    lib.findFirst (fitted: builtins.length fitted <= room) [ ] (map packed (downward count));

  entries =
    sets:
    map (name: {
      separator = ", ";
      text = "${shown name} ${only sets.old sets.new name} -> ${only sets.new sets.old name}";
    });
  cves = fill 1 (
    lib.imap0 (index: patch: {
      separator = ", ";
      text = "${lib.optionalString (index == 0) "patch "}${patch.cve} in ${patch.package}";
    }) patched
  );

  heldNames = changed held;
  beneathNames = changed beneath;
  head =
    if heldNames != [ ] then
      subject held heldNames ""
    else if beneathNames != [ ] then
      subject beneath beneathNames "dependencies "
    else
      "build: update ${listed moved}, ${toString rebuilt} rebuilt, no version changed";
  versions = if heldNames != [ ] then entries held heldNames else entries beneath beneathNames;
  body = fill (lines - builtins.length cves) versions ++ cves;
in
"${head}\n${lib.optionalString (body != [ ]) "\n${lib.concatStringsSep "\n" body}\n"}"
