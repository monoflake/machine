# A machine's SSH, root by the machine's keys and never by a password, and on a fetched machine
# its builders as the user machine-cache, nix/cache/fetch.nix.
{ config, lib, ... }:
{
  services.openssh = {
    enable = true;
    openFirewall = lib.mkDefault false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users = {
    mutableUsers = false;
    users.root.openssh.authorizedKeys.keys = config.machine.keys;
  };
}
