# A failed mount

**A failed mount never stops a machine's network**, decided by the author on 2026-10-25: a machine
has no console but its provider's, often none, so a missing data disk must leave it on the tailnet
to be looked at, not in an emergency shell.

- `systemd.enableEmergencyMode` is off, so a failed mount boots on.
- `/data` is mounted `nofail`, so its absence fails no target, and every unit that needs it,
  containerd, the driver, its entry and socket, conform's second driver, the swap file and its
  `mkswap`, carries `RequiresMountsFor=/data` and stays down without it rather than failing in a
  loop. sshd, the network, tailscaled, nftables and the fence need nothing of `/data`.
- The swap file on `/data` stays in fstab, `noauto`, out of `swap.target`, which `sysinit.target`
  waits for, and is pulled in by `multi-user.target` once `/data` is there. It stays in fstab
  because switch-to-configuration-ng swaps off a device gone from fstab, which on a machine of one
  gigabyte with swap in use can bring the OOM killer, provisional, chosen by the advisor on
  2026-10-25.
- `/run/machine/degraded` names each mount that failed or is missing, a line each, written after
  `local-fs.target` and again whenever such a mount starts, and removed once every one is there;
  an interactive login shows it.
