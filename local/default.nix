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

  # Docker gives the address, the public nameservers and its name for this computer, and publishes
  # only ssh, the entry and the driver, on localhost, scripts/local.res.
  networking = {
    useDHCP = lib.mkForce false;
    resolvconf.enable = false;
    # NixOS's firewall runs as on a real machine, Docker's eth0 trusted in the tailnet's place.
    firewall.trustedInterfaces = [ "eth0" ];
  };
  services.tailscale.enable = lib.mkForce false;
  services.openssh.hostKeys = [
    {
      path = "${state}/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }
  ];

  machine = {
    name = "local";
    # A container's labels are placeholders nothing reads, docs/names.md.
    provider = "selfhost";
    region = "us-west";
    account = "local";
    # Neither is read in a container, which has no disk of its own to install to and takes no swap.
    disk = "/dev/null";
    memory = 4096;
    # monoflake/platform's conform runs a second driver here beside the live one.
    conform.enable = true;
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
    # The control run on the developer's computer, `wrangler dev`, by the name Docker gives it.
    plain = "http://host.docker.internal:8787";
  };

  system.stateVersion = "26.05";
}
