# The store

How a machine keeps its Nix store from filling its disk, `system/nix/collect.nix`.

**Every machine collects its store every six hours and sets Nix's `min-free` and `max-free`**,
decided by the author on 2026-10-26, after a builder's root filesystem reached 93% and a run failed
with no space left. The values are provisional, chosen by the advisor on 2026-10-26. Staging a
cache run on `/data` came with the build store, [cache.md](cache.md); a free space check before a
run was not adopted.

## The collection

`nix.gc.dates` is `*-*-* 00/6:00:00`, so the `nix-gc` timer fires at 00:00, 06:00, 12:00 and 18:00
by the machine's clock: in [systemd.time(7)](https://www.freedesktop.org/software/systemd/man/260/systemd.time.html),
the systemd 260.5 the locked nixpkgs carries, an hour of `00/6` matches 0 and every multiple of 6
after it. The timer stays `Persistent`, so a collection missed while the machine was off runs when
it comes back. In the locked nixpkgs,
[nix-gc.nix](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/nixos/modules/services/misc/nix-gc.nix#L86-L100)
turns `dates` into the service's `startAt`, and
[systemd.nix](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/nixos/modules/system/boot/systemd.nix#L777-L781)
makes that the timer's `OnCalendar`.

Two things stay as they were. Before each collection the system profile keeps its last three
generations, `--delete-generations +3`, as the boot menu keeps them, RFC vr5lw. A path unit on
`/nix/var/nix/profiles` starts the same collection whenever a new system lands there.

## `min-free` and `max-free`

`nix.settings.min-free` is 1 GiB and `max-free` 2 GiB, in bytes, on every machine. When a store
has less than `min-free` free, Nix collects its garbage until `max-free` is free or nothing is left
to collect, as the
[2.34 manual](https://nix.dev/manual/nix/2.34/command-ref/conf-file.html#conf-min-free) says of
a build. The source of Nix 2.34.9, the version the locked nixpkgs selects, says when, where and for
which stores:

- **When it looks.** A local store checks its free space in its worker's goal loop, which runs for
  every build and every substitution
  ([worker.cc L348-L350](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/build/worker.cc#L348-L350)),
  waking every ten seconds while `min-free` is set
  ([L419-L423](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/build/worker.cc#L419-L423)),
  and again before writing each path it adds
  ([local-store.cc L1098](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/local-store.cc#L1098)
  and [L1231](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/local-store.cc#L1231)), at
  most once every `min-free-check-interval`, five seconds by default
  ([local-settings.hh L87-L118](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/local-settings.hh#L87-L118)).
  An idle machine never looks; the timer above covers it.
- **Where it looks.** The free space is `statvfs` of the store's own physical store directory
  ([gc.cc L816-L825](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/gc.cc#L816-L825)): the
  root filesystem for the main store, and the whole `/data` filesystem for a builder's chroot store
  at `local?root=/data/build/root`.
- **Which stores.** The settings are global, though written per store
  ([local-settings.hh L152-L171](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/local-settings.hh#L152-L171),
  [globals.hh L121-L129](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/globals.hh#L121-L129)),
  so every local store a process opens obeys them: the daemon's main store, the main store a root
  command opens itself, as the fetch's `nix-store --realise` does, and a cache run's chroot store,
  which is collected the same way once the whole `/data` filesystem has under 1 GiB free.
- **What it frees.** Below `min-free`, and below `max-free`, a background collection frees
  `max-free` minus the space free, between 1 and 2 GiB here, honoring the store's permanent and
  temporary roots ([gc.cc L848-L886](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/gc.cc#L848-L886)).
  The free space the last collection left is kept in the store object's own state
  ([local-store.hh L189-L217](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/local-store.hh#L189-L217)),
  so per process, and in the daemon per connection, since each connection's process opens a store
  of its own ([daemon.cc L328-L354](https://github.com/NixOS/nix/blob/2.34.9/src/nix/unix/daemon.cc#L328-L354)).
  While free space stays above 97% of that figure, the same store object starts no new collection
  ([gc.cc L851-L852](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/gc.cc#L851-L852)); a
  new process or connection starts with no figure and may collect again at once.

**The build store's quota bounds a run, and `min-free` never sees it.**
`system/nix/cache/store.nix` limits the `/data/build` subvolume to a 10 GB qgroup. A write past it
fails with `EDQUOT`, which btrfs returns from
[qgroup_reserve](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/btrfs/qgroup.c?h=v6.18#n3563)
without logging anything, and the run fails. `statfs` ignores qgroups, as
[btrfs_statfs](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/btrfs/super.c?h=v6.18#n1733)
reads no qgroup at all in Linux 6.18, the locked nixpkgs' default kernel, so `min-free` measures
`/data` as a whole and does not fire at the quota. What keeps the quota from filling over many runs
is the run's own reclaim when it ends, its `TMPDIR` emptied and its chroot store collected,
[cache.md](cache.md). An operator finds it in the run unit's journal, `machine-cache-<name>`,
`machine-cache-now@<name>` or `machine-cache-self`, as `Disk quota exceeded`: Nix writing a path into the chroot
store prints `error: write of <n> bytes: Disk quota exceeded`
([file-descriptor.cc L45-L56](https://github.com/NixOS/nix/blob/2.34.9/src/libutil/unix/file-descriptor.cc#L45-L56),
its message and `strerror` joined by
[SystemError](https://github.com/NixOS/nix/blob/2.34.9/src/libutil/include/nix/util/error.hh#L312-L325)),
a builder prints its own tool's error with the same text before Nix reports the build failed, and
the run's last line is `machine-cache outcome=failed`. The chroot store's database sits under the
same quota, and a write to it that meets the quota may surface as SQLite's `disk I/O error`
instead, so a failed run with that error on a builder is read the same way.

What it leaves to others: only store paths are collected. A cache run's staging directory, its
`TMPDIR` and the build directories on `/data` are files, not store paths; the run reclaims them,
and collects its chroot store, when it ends, [cache.md](cache.md). Container images and logs are
not store paths either.

## A fetched system is rooted from its realization

A collection every six hours makes the window between taking a system and switching to it matter.
`system/nix/cache/fetch.sh` realizes the system its pointer names with
`nix-store --realise <path> --add-root <work>/system` every time, whether the store already holds
it or not, and only then sets the system profile. In 2.34.9,
[opRealise](https://github.com/NixOS/nix/blob/2.34.9/src/nix/nix-store/nix-store.cc#L134-L185)
calls [realisePath](https://github.com/NixOS/nix/blob/2.34.9/src/nix/nix-store/nix-store.cc#L117-L130),
which with `--add-root` calls
[addPermRoot](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/indirect-root-store.cc#L18-L43)
in the same process as the substitution: a temporary root again, the link in the work directory,
then [addIndirectRoot](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/gc.cc#L41-L46) in
`gcroots/auto`. Until then each path holds the temporary root its
[substitution goal](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/build/substitution-goal.cc#L29-L38)
takes before it even checks the path is valid. Before the goal starts, the realization's own
missing-path query and its automatic collection check run unrooted for a moment; a concurrent
collection there can take a valid but unrooted system, and the goal then finds it invalid and
substitutes it again with the same trust, failing before the profile if it cannot. A path already valid is neither queried nor fetched: the goal stops at its
validity check, and the realization's
[queryMissing](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/misc.cc#L279-L284) passes a
valid path over, so an already valid system is rooted without reaching the bucket. The profile's
own generation link roots it next.

The work directory goes when the fetch exits, by its exit trap, after which a collection removes
the link it left in `gcroots/auto` as
[stale](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/gc.cc#L240-L252). A fetch killed
with `SIGKILL` runs no trap, so `<work>/system` stays under the temporary directory and roots that
system until the directory is cleaned.

The realization keeps its trust as [cache.md](cache.md) describes: the bucket and the machine's own
substituters, the builders' keys and the machine's own trusted keys, `require-sigs` and no cached
negative lookup, RFC ttcli. The profile command after it takes
nothing from the bucket. A builder's own system and the systems it builds for others are rooted as
[cache.md](cache.md) describes, the self build by its profile command and every build by its run's
out-link.

## Tests

`system/nix/collect-test.nix` evaluates a machine for both Linux architectures and checks the
timer's calendar, its persistence, the two settings in bytes, the three generations kept and the
path unit:

```sh
nix eval --impure --json --file system/nix/collect-test.nix --apply 'f: f {}'
```

`system/nix/cache/tests/fetch/gc-test.sh` runs the fetch against a real disposable main store that
requires signatures, a real directory bucket signed with a generated key, and a system with a
reference, and collects the main store right after each of the fetch's store commands and again
after the fetch. In its `fetched` mode the main store lacks the system and the fetch takes it from
the bucket; in its `valid` mode the main store already holds it unrooted and the bucket no longer
can, so only the fetch's own root keeps it. In both the system and its reference survive, the
profile holds the system, the switch ran, and no root in the work directory outlives the fetch. The
real store also receives the same small toplevel, because the fetch runs its switch by its path.
`system/nix/cache/tests/fetch/protocol-test.sh` checks the realization's root and trust options
among the pointer protocol's cases.
