# A machine's ground, its clock on UTC, a small journal, and no documentation or default packages.
{
  time.timeZone = "UTC";
  services.journald.extraConfig = "SystemMaxUse=256M";
  documentation.enable = false;
  environment.defaultPackages = [ ];
  # A failed mount never stops the boot on a console nobody watches, so the network comes up.
  systemd.enableEmergencyMode = false;
}
