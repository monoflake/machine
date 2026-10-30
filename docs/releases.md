# Released inputs

**The OS is the latest stable release, what it takes newer is nixos-unstable's, and a named
exception is nixpkgs-unstable's**, decided by the author on 2026-10-29. The flake's `nixpkgs` input
follows the release channel, today `nixos-26.05`, and builds the system. `unstable`, `nixos-unstable`
as `pkgs.unstable`, is where software newer than the release comes from by default, RFC vr5lw:
containerd, the runtimes, btrfs-progs and the maintenance tools. `latest`, `nixpkgs-unstable` as
`pkgs.latest`, takes only what the author names, and today that is Tailscale alone: it is the
network layer and tracks the newest release, and `nixos-unstable` advances only once Hydra's NixOS
tests pass where `nixpkgs-unstable` waits on a smaller set, so a fix can sit on `nixpkgs-unstable` a
day or more first, as 1.104.4's
vulnerability fix did on 2026-10-29 while `nixos-unstable` held 1.104.2. Nothing else moves to
`latest` unless the author names it. The update workflow moves all three with the flake's lock,
and its message names Tailscale's version when it changes.

**The Nix that builds, evaluates, signs or asks upstream for the fleet is the OS channel's,
taken from the lock**, decided by the author on 2026-10-29. It moves only when the lock moves.
CI takes its client through the mise path and its daemon through `channel daemon`;
`nix-installer` only bootstraps. The author's Mac takes its client through the mise path and
runs upstream Nix installed by NixOS/nix-installer, never Determinate Nix, its version held by
root's default profile. Only `mise run //repos/monoflake/machine:channel mac` changes it, asking
for sudo when the daemon differs from the channel, as the resolver's warning says. It installs
by name, keeping nss-cacert, and restarts the daemon. `nix upgrade-nix`, which takes Nix's latest
release rather than the channel's, `nix-env --set`, rerunning the installer and Determinate Nix
are never used. Rollback is `sudo nix-env --profile /nix/var/nix/profiles/default --rollback`
followed by `sudo launchctl kickstart -k system/org.nixos.nix-daemon`, except after the first
switch: the installer's `/nix/var/nix/profiles/per-user/root/profile` is kept as the fallback and a
GC root, and the default chain then starts anew with one generation, so the restore is `sudo ln
-sfn per-user/root/profile /nix/var/nix/profiles/default` before the same kickstart, as `channel
mac` prints. The launchd job
`systems.determinate.nix-installer.nix-hook` keeps its name and runs `/nix/nix-installer repair`
at boot to restore the shell hook after a macOS update; its name comes from the installer's
origin, and renaming it would desync `/nix/receipt.json` and the installer's uninstall.

**A machine takes the released driver as it takes the runtimes' images**, monoflake/driver's RFC
8c0rg. `system/containers/manifest.toml` names each source, monoflake/runtime's images at its top
and monoflake/driver's `driver-machine` in its `[driver]` table, and the workspace's
`scripts/deps/releases.res` locks the newest version each source's releases list in
`manifest.lock` at `mise run update`. The update workflow moves that lock with the flake's inputs
and names the driver's version in its message beside the runtimes'.

**The driver is fetched like any other source**, decided by the author on 2026-10-27. Each
architecture's entry in the lock is its one GitHub Releases URL and its SHA-256; whichever builder
builds a system fetches the archive by that fixed output and packages it, and the package travels
by the cache's own rules, an own path reaching the object storage through the cache, RFC mgzfp. The
release needs no bucket of its own.

**`machine.driver.package` defaults to that package** on the host's architecture, set in
`system/driver.nix` by `lib.mkDefault`, so a package a configuration sets replaces it. A test
machine's `machine.driver.override` stands in for it and leaves the default null. Until the first
release is locked the lock holds no driver entry and the default is null, so a machine enabling the
driver sets a package or an override; no invented hash enters a system.

**`.github/update/driver-test.sh` evaluates the package on both Linux systems** and fetches
nothing: once from this checkout's lock, and once from a copy whose lock is the hand-written
`.github/update/driver.lock`, which no configuration reads. It holds the package's version, its one
URL and hash, both services' executable and the override. The update workflow runs it once the lock
has moved.
