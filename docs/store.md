# The store

How a machine keeps its Nix store from filling its disk, `system/nix/collect.nix`.

**Every machine collects its store every six hours and sets Nix's `min-free` and `max-free`**.

## The collection

`nix.gc.dates` is `*-*-* 00/6:00:00`, so the `nix-gc` timer fires at 00:00, 06:00, 12:00 and 18:00
by the machine's clock: in
[systemd.time(7)](https://www.freedesktop.org/software/systemd/man/260/systemd.time.html), the
systemd 260.5 the locked nixpkgs carries, an hour of `00/6` matches 0 and every multiple of 6 after
it. The timer stays `Persistent`, so a collection missed while the machine was off runs when it
comes back. In the locked nixpkgs,
[nix-gc.nix](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/nixos/modules/services/misc/nix-gc.nix#L86-L100)
turns `dates` into the service's `startAt`, and
[systemd.nix](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/nixos/modules/system/boot/systemd.nix#L777-L781)
makes that the timer's `OnCalendar`.

**Before each collection the system profile keeps a generation only while it is among the newest
three and younger than three days**, the booted and the current one always, RFC 79bz5; the boot menu
still keeps three. A path unit on `/nix/var/nix/profiles` starts the same collection whenever a new
system lands there.

## `min-free` and `max-free`

`nix.settings.min-free` is 1 GiB and `max-free` 2 GiB, in bytes, on every machine. When a store has
less than `min-free` free, Nix collects its garbage until `max-free` is free or nothing is left to
collect, as the [2.34
manual](https://nix.dev/manual/nix/2.34/command-ref/conf-file.html#conf-min-free) says of a build.
The source of Nix 2.34.9, the version the locked nixpkgs selects, says when, where and for which
stores:

- **When it looks.** A local store checks its free space in its worker's goal loop, which runs for
  every build and every substitution ([worker.cc
  L348-L350](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/build/worker.cc#L348-L350)),
  waking every ten seconds while `min-free` is set
  ([L419-L423](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/build/worker.cc#L419-L423)),
  and again before writing each path it adds ([local-store.cc
  L1098](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/local-store.cc#L1098) and
  [L1231](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/local-store.cc#L1231)), at most once
  every `min-free-check-interval`, five seconds by default ([local-settings.hh
  L87-L118](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/local-settings.hh#L87-L118)).
  An idle machine never looks; the timer above covers it.
- **Where it looks.** The free space is `statvfs` of the store's own physical store directory
  ([gc.cc L816-L825](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/gc.cc#L816-L825)), the
  root filesystem for the main store.
- **Which stores.** The settings are global, though written per store ([local-settings.hh
  L152-L171](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/local-settings.hh#L152-L171),
  [globals.hh
  L121-L129](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/globals.hh#L121-L129)),
  so every local store a process opens obeys them: the daemon's main store and the main store a root
  command opens itself.
- **What it frees.** Below `min-free`, and below `max-free`, a background collection frees
  `max-free` minus the space free, between 1 and 2 GiB here, honoring the store's permanent and
  temporary roots ([gc.cc
  L848-L886](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/gc.cc#L848-L886)). The free space
  the last collection left is kept in the store object's own state ([local-store.hh
  L189-L217](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/local-store.hh#L189-L217)),
  so per process, and in the daemon per connection, since each connection's process opens a store of
  its own ([daemon.cc
  L328-L354](https://github.com/NixOS/nix/blob/2.34.9/src/nix/unix/daemon.cc#L328-L354)). While free
  space stays above 97% of that figure, the same store object starts no new collection ([gc.cc
  L851-L852](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/gc.cc#L851-L852)); a new process
  or connection starts with no figure and may collect again at once.

What it leaves to others: only store paths are collected. Container images and logs are not store
paths. A system the update path takes is rooted from its realization until its profile holds it,
[update.md](update.md).

## Tests

`system/nix/collect-test.nix` evaluates a machine for both Linux architectures and checks the
timer's calendar, its persistence, the two settings in bytes, the generations' pruning and the path
unit:

```sh
nix eval --impure --json --file system/nix/collect-test.nix --apply 'f: f {}'
```
