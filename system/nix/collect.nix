# How a machine collects its store, every six hours and whenever a new system lands, docs/store.md.
{ config, ... }:
{
  nix = {
    # The last three systems kept, as the boot menu keeps them, until the driver holds them, RFC
    # vr5lw.
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
    services.nix-gc.preStart = "${config.nix.package}/bin/nix-env --profile /nix/var/nix/profiles/system --delete-generations +3";
    # A new system also collects, as the profile's link is renamed in this directory, which the
    # collection's own deletions do not trigger again.
    paths.nix-gc = {
      wantedBy = [ "paths.target" ];
      pathConfig.PathChanged = "/nix/var/nix/profiles";
    };
  };
}
