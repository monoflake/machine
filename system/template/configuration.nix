# What this machine is alone; the rest is the platform's module.
{
  imports = [ ./hardware-configuration.nix ];
  machine = {
    name = "alder";
    hostname = "alder-box";
    prettyName = "Alder";
    region = "us-west";
    provider = "selfhost";
    account = "example";
    disk = "/dev/vda";
    memory = 4096;
    keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderReplaceWithYourOwnPublicKey0000" ];
    # tailnet.authKeyFile = "/var/lib/secrets/tailnet";
    # upgrade = {
    #   flake = "git+ssh://git@github.com/you/machines?dir=machine";
    #   at = "04:00";
    # };
  };
  # machine.driver = {
  #   enable = true;
  #   override = "/var/lib/driver-machine/dev/driver-machine";
  #   bindings = [ "/var/lib/secrets/binding" ];
  # };
  system.stateVersion = "26.05";
}
