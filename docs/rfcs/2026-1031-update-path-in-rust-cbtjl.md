---
name: 'Update path in Rust'
title: "The update path and the address discovery are rewritten in Rust where their shell lives, reaching Nix through harmonia's libraries and reading the bucket themselves"
status: accepted
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

A machine's update path, `system/nix/update/`, and its address discovery, the
`discover` script of `system/network/addresses/`, are POSIX shell around `jq`, `curl`, `ssh-keygen`,
`systemctl`, `flock`, `nix-store` and `nix-env`: about 470 lines, with about 910 more of shell
tests. On 2026-10-30 the author decided that what a machine runs is Rust, its I/O through typed
Rust APIs and not subprocesses, which cannot be tested on the Mac, return unstructured text and
drift or lag on an upgrade, so that a crate's API catches an upgrade's change at compile time;
sync or async is decided by the workload. Two questions were left open: when the rewrite happens,
and how a Rust program reaches Nix.

## Options

Weighed on 2026-10-31; the author chose harmonia's libraries, and the bucket read by the program
itself.

- **The Nix CLI kept as the one exception**: everything else in Rust, `nix-store` and `nix-env`
  still subprocesses.
- **gorgon's `nix-daemon`**: a daemon client with a clean API, without `AddToStoreNar`.
- **snix's `nix-compat`**: the wire format, NAR and narinfo, its daemon side a server only.
- **tweag's `nix-remote`**: typed worker operations made for a proxy, its protocol fixed at 1.35.
- **nix-community's harmonia, as libraries**: `harmonia-store-remote`, a daemon client, with the
  store path, narinfo and signature types beside it.
- **Our own client**, written from Nix's source and snix's protocol notes.

For the bucket, with the daemon substituting from it the daemon would hold its credentials, or a
localhost proxy signing each request would stand between them; with the program reading the bucket
itself, the credentials stay where they are now, in the update unit alone.

## Evidence

Measured by the advisor on 2026-10-31, license aside at the author's word:

| Candidate           | Stars | Last change                      | Registry                  |
| ------------------- | ----- | -------------------------------- | ------------------------- |
| harmonia            | 639   | 2026-10-25, v3.3.0 on 2026-09-18 | not published, git only   |
| gorgon `nix-daemon` | 21    | crate 0.1.1 on 2024-07-16        | 2589 downloads, 35 recent |
| snix `nix-compat`   | 24    | 2026-10-30                       | a placeholder, 838        |
| tweag `nix-remote`  | 50    | 2025-07-22                       | 2736 downloads, 2 recent  |

A probe of harmonia's client and one of gorgon's each ran a handshake, `IsValidPath`,
`QueryPathInfo`, `AddTempRoot`, `SetOptions` overriding the substituters, and `EnsurePath` of a
missing path, against the Mac's Nix 2.34.9 daemon, untrusted, and against ci-raleigh's as root
through a forwarded socket, trusted. Both passed every step in both places; on ci-raleigh a bogus
substituter was refused and the public cache then served the path, in 0.2 to 0.8 s. harmonia alone
also carries `AddToStoreNar`, `AddPermRoot` and `AddIndirectRoot`, and speaks protocol 1.37 to
1.38. harmonia is MIT and every crate of the probe's tree is permissively licensed; gorgon's is
EUPL-1.2 and snix's GPL-3.0.

## Decision

1. **It is done now**, before RFC oej2a's step 5, as the author decided on 2026-10-31: A and B are
   frozen and only the test platform runs the update path, so it is tried there by pointer and no
   other machine is touched.
2. **The scope is the update path and the address discovery**: `fetch`, `driver`,
   `driver-links`, `driver-protocol`, `nudge`, `protocol` and `rollback` under
   `system/nix/update/`, and the `discover` script. `system/nix/cache/` and `builder/` stay as they are,
   being the old builders' code that oej2a removes after the reset.
3. **The Rust lives where its shell lives**, a crate under `system/nix/update/` and one under
   `system/network/addresses/`, members of a Cargo workspace this repository starts at its root,
   each built by Nix, the shell it replaces removed as item 7 says.
4. **Nix is reached through harmonia's libraries**, never its binaries:
   `harmonia-store-remote` for the daemon, with `harmonia-store-path`, `harmonia-store-nar-info`
   and `harmonia-utils-signature`, as git dependencies pinned to a release tag. The one program
   run is the system's own `switch-to-configuration`, which is what is being installed, not a
   tool. Setting the system profile is a generation link written as `nix-env --set` writes it.
5. **The program reads the bucket itself**: a typed S3 client with the systems credentials reads
   each narinfo and NAR the closure misses, checks its signature against the machine's trusted
   keys, and streams the NAR, zstd as CI uploads it, into `AddToStoreNar`, references before
   referrers. A path the bucket lacks is upstream's, and the daemon fetches it by `EnsurePath`.
   The daemon never holds the bucket's credentials. A pointer's signature is checked by the
   `ssh-key` crate in place of `ssh-keygen -Y`.
6. **The address discovery** reads interface addresses over netlink, the trace over an HTTP client
   bound to each family, and names through a resolver crate. How it takes Tailscale's netcheck,
   its LocalAPI or a STUN client of its own, is settled with the author before that part starts.
7. **The shell tests' cases are carried over** as Rust tests, run on the Mac against a fake bucket
   and the Mac's own daemon. The shell of a part is removed once its Rust has taken a pointer on
   okra, sora and oak.
8. **Settled at its first wave, with the advisor on 2026-10-31.** `cargo deny check` runs in
   verify with monoflake/driver's allowed licenses, harmonia's repository the one git source, so a
   copyleft dependency is refused. `rust-version` is the release's rustc, 1.95, which builds it on
   a machine. HTTPS is rustls on aws-lc-rs by default, ring behind a feature, the OpenSSL license
   allowed for aws-lc-sys in this repository alone, decided by the author on 2026-10-31; verify
   lints and tests both. Its tests take a temporary store under `nix daemon --force-trusted`, and
   `AddToStoreNar` keeps the daemon's own signature check, so the program and the daemon both
   verify each path. A read from the bucket stalls out after 300 seconds, the bound Nix's
   stalled-download-timeout gave the shell, and a driver archive's download has none, as the
   shell's curl had none, decided by the author on 2026-10-31. **Every line it prints is the
   shell's word for word**, read by cloud's nudge, but for the detail lines before a failed realise
   or restart, which were the tool's own output and are now the error's.

The update path's final step is done on 2026-10-31, after the fleet's test machines took both
pointers and the driver through Rust. Its replaced shell and shell tests are removed, with the
eval tests and recorded behavior transcripts retained.

9. **ring for a CPU aws-lc's entropy source aborts on**, decided by the author on 2026-11-01: on
   pine's board the first TLS handshake's `RAND_bytes` reached aws-lc 0.47's tree jitter entropy
   source, whose one-time initialization called `abort()`, so `machine-update-fetch` died with
   SIGABRT after "update: fetching system pointer" and no line of its own. `machine.update.tls`
   picks the build, aws-lc-rs by default and ring where set, pine alone.
10. **The update path says which step it was in when it is aborted**, built on 2026-11-01. A C
    dependency's `abort()` passes every Rust panic hook, so the journal held only the core dump.
    `machine-update-fetch`, `machine-update-nudge` and `machine-driver-rollback` each install a
    SIGABRT handler that writes `update: aborted by SIGABRT, last step <step>` on standard error,
    the last step `Output::say` printed or `none`, restores the default action and raises the signal
    again, so the core dump and the exit status stay. **The crate holding it,
    `system/nix/update/abort`, is the fleet repositories' one deliberate allowance of `unsafe`**,
    chosen by the author on 2026-11-01, because a C abort reaches nothing of Rust's but a signal
    handler and the calls a handler needs have no safe form. Its public API is safe,
    `machine-update` stays `forbid`, and its lint table is the workspace's but for `unsafe_code`,
    which its test holds.

## State

Written on 2026-11-01. The update path is built in Rust, and the address discovery is not.

Built: the root `Cargo.toml` lists the `machine-update` crate at `system/nix/update/` and the
`abort` crate under it. The crate builds `machine-update-fetch`, `machine-update-nudge` and
`machine-driver-rollback`. `src/store.rs` calls `AddToStoreNar` through harmonia, `src/bucket.rs`
reads the bucket, and `docs/update.md` states the rule. The update path's shell and shell tests
are gone. `system/nix/cache/` is gone too.

Not built: the address discovery. `system/network/addresses/default.nix` still wraps
the discover script in `writeShellApplication` with `curl`, `jq` and `iproute2`, its shell tests and
`parse.jq` remain, and the root `Cargo.toml` has no crate for it. Item 6's question about
Tailscale's netcheck, LocalAPI or a STUN client is therefore still open.

A claim in item 2 is wrong about the present. `builder/` is not removed code. `builder/entry.sh` is
live: `scripts/builder.res` reads it, `mise.toml` has the `builder` task, and `docs/local.md`
describes the container it starts on a developer's computer for building a system. What RFC oej2a
retired is the fleet's builder cache, which was `system/nix/cache/`, and `builder/` stays.

The seed's render and boot scripts under `system/base/seed/` are neither in item 2's scope nor scheduled:
they still run at boot, `docs/network.md`, and no RFC here decides whether they are rewritten.
