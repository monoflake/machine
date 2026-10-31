# How a fleet machine boots, GRUB on BIOS and EFI, its console base/console.nix.
{
  imports = [ ./disk.nix ];

  # BIOS and EFI on a PC; EFI alone on Arm, which has no BIOS GRUB, so its partition idles.
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    configurationLimit = 3;
  };
}
