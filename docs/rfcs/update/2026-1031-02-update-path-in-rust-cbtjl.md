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
