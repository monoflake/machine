# Released inputs

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
