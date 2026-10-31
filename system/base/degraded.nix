# The mark of a mount missing, `/run/machine/degraded` naming each by its mount point and device,
# read again whenever one is mounted, removed once all are there, shown at an interactive login.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  marker = "/run/machine/degraded";
  # Every file system mounted at boot, as fstab lists it, and its unit.
  mounts = lib.filter (fs: !(lib.elem "noauto" fs.options)) (lib.attrValues config.fileSystems);
  units = map (fs: "${utils.escapeSystemdPath fs.mountPoint}.mount") mounts;
  mountpoint = lib.getExe' pkgs.util-linux "mountpoint";
  # One line for each mount not there.
  missing = lib.concatMapStringsSep "\n" (
    fs:
    let
      named = "${fs.mountPoint} from ${fs.device} is not mounted";
    in
    "${mountpoint} -q ${lib.escapeShellArg fs.mountPoint} || echo ${lib.escapeShellArg named}"
  ) mounts;
in
{
  systemd.services.degraded = {
    description = "The mark of a mount missing";
    # Run at boot and again each time a mount is started, as by a switch, which never reboots.
    wantedBy = [ "multi-user.target" ] ++ units;
    # After each mount has come up or failed, as one marked nofail is not ordered before
    # local-fs.target.
    after = [ "local-fs.target" ] ++ units;
    serviceConfig.Type = "oneshot";
    script = ''
      missing=$(${missing})
      if [ -z "$missing" ]; then
        rm -f ${marker}
        exit
      fi
      mkdir -p ${dirOf marker}
      echo "$missing" > ${marker}.new && mv ${marker}.new ${marker}
    '';
  };

  # Shown at an interactive login alone, as /etc/bashrc reads /etc/profile for a command over ssh.
  environment.loginShellInit = ''
    if [[ $- == *i* && -r ${marker} ]]; then cat ${marker}; fi
  '';
}
