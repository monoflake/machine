# A test machine as a container in Docker on a developer's computer, started by `mise run local`,
# its disk a loop file, no tailnet, and a binding token made on it at first boot, RFC n0o4l.
{ lib, pkgs, ... }:
let
  # What outlives the container, a volume of its own.
  state = "/var/lib";
  disk = "${state}/disk/data.img";
  binding = "${state}/driver-machine/binding";
in
{
  boot = {
    isContainer = true;
    loader.grub.enable = lib.mkForce false;
  };
  disko.enableConfig = false;

  # Docker gives the address and binds /etc/resolv.conf, and publishes only ssh and the entry, on
  # localhost.
  networking = {
    hostName = "local";
    useDHCP = lib.mkForce false;
    resolvconf.enable = false;
    firewall.enable = lib.mkForce false;
  };
  services.tailscale.enable = lib.mkForce false;
  services.openssh.hostKeys = [
    {
      path = "${state}/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }
  ];

  machine = {
    # Neither is read in a container, which has no disk of its own to install to and takes no swap.
    disk = "/dev/null";
    memory = 4096;
  };

  # btrfs with simple quotas, as a machine's data partition is, sparse until written.
  fileSystems."/data" = {
    device = disk;
    fsType = "btrfs";
    options = [
      "loop"
      "noatime"
    ];
  };
  systemd.services = {
    local-disk = {
      description = "The local machine's data disk, made once";
      before = [ "data.mount" ];
      requiredBy = [ "data.mount" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        [ -f ${disk} ] && exit
        mkdir -p "$(dirname ${disk})" && truncate -s 16G ${disk}.new
        ${pkgs.unstable.btrfs-progs}/bin/mkfs.btrfs -q -O squota ${disk}.new && mv ${disk}.new ${disk}
      '';
    };
    # The binding's token, `<id>.<secret>`, never leaving the machine but by ssh.
    local-binding = {
      description = "The local machine's binding token, made once";
      before = [ "driver-machine.service" ];
      requiredBy = [ "driver-machine.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      script = ''
        [ -s ${binding} ] && exit
        mkdir -p "$(dirname ${binding})"
        echo "1.$(head -c 32 /dev/urandom | basenc --base64url | tr -d '=\n')" > ${binding}
      '';
    };
  };

  machine.driver = {
    enable = true;
    override = "/var/lib/driver-machine/dev/driver-machine";
    local = "/var/lib/driver-machine/artifacts";
    bindings = [ binding ];
    # Docker's published port reaches the container's own interface, never its loopback.
    entry = "0.0.0.0:36879";
  };

  system.stateVersion = "26.05";
}
