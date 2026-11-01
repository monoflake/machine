# How a machine collects its store, every six hours and whenever a new system lands, docs/store.md.
{ config, pkgs, ... }:
let
  # A system is kept while among the newest three and younger than three days, the booted and the
  # current one always, RFC 79bz5.
  pruned = pkgs.writeShellScript "system-generations-pruned" ''
    set -eu
    profile=''${PROFILE:-/nix/var/nix/profiles/system}
    booted=$(readlink -f ''${BOOTED:-/run/booted-system} || true)
    current=$(readlink -f "$profile")
    cutoff=$(( $(date +%s) - 3 * 86400 ))
    numbers=$(for link in "$profile"-*-link; do
      [ -L "$link" ] || continue
      n=''${link#"$profile"-}
      echo "''${n%-link}"
    done | sort -n)
    newest=$(echo "$numbers" | tail -n 3)
    gone=""
    for n in $numbers; do
      link="$profile-$n-link"
      target=$(readlink -f "$link")
      [ "$target" = "$current" ] && continue
      [ "$target" = "$booted" ] && continue
      if ! echo "$newest" | grep -qx "$n" || [ "$(stat -c %Y "$link")" -lt "$cutoff" ]; then
        gone="$gone $n"
      fi
    done
    [ -n "$gone" ] || exit 0
    echo "deleting system generations$gone"
    [ -z "''${DRY:-}" ] || exit 0
    ${config.nix.package}/bin/nix-env --profile "$profile" --delete-generations $gone
  '';
in
{
  nix = {
    gc = {
      automatic = true;
      dates = "*-*-* 00/6:00:00";
      persistent = true;
    };
    # A store left under 1 GiB free while it builds or takes a path collects until 2 GiB are free.
    settings = {
      min-free = 1024 * 1024 * 1024;
      max-free = 2 * 1024 * 1024 * 1024;
    };
  };
  systemd = {
    services.nix-gc.preStart = "${pruned}";
    # A new system also collects, as the profile's link is renamed in this directory, which the
    # collection's own deletions do not trigger again.
    paths.nix-gc = {
      wantedBy = [ "paths.target" ];
      pathConfig.PathChanged = "/nix/var/nix/profiles";
    };
  };
}
