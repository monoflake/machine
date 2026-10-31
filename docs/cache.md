# The cache

How a machine too small to evaluate its own system takes its daily upgrade, `system/nix/cache/`,
built for monoflake/cloud's RFC u9fxz and its amendment, RFC dpcnp, and reshaped by RFC ttcli: a
builder evaluates and builds the machine's system, uploads the paths of its closure upstream lacks
to a bucket on Cloudflare R2, and writes a signed pointer to it; the machine fetches the pointer,
takes the paths from the bucket and upstream, and switches.
`machine.cache` in `system/options.nix` sets both roles, and `machine.cache.enable` turns them on
once the bucket and its keys exist.

## A builder's run

A machine named in `machine.cache.builds` gets a unit `machine-cache-<name>` on its builder. With
one unnamed builder, `builds.<name>.builders` empty, it is timed at its `at` or started by hand
where `at` is null, as on a fallback builder; with a deployment's inventory it fires at each of the
machine's slots and runs at the builder's own alone, below. `machine-cache-now@<name>` starts the
same run at once, skipping the wait for its slot but not the check for a fresh answer. A run missed
while the builder was off is skipped, never caught up. **A builder's runs never overlap**: each
holds `/run/lock/machine-cache` by `flock`, so no two evaluations meet in its memory. A run,
`run.sh`, for its one machine, first uploads `nix-cache-info` again once it holds the lock,
whether it then builds, finds an answer, meets a claim or confirms, so the lifecycle rule never
takes it while runs go on, provisional, chosen by the advisor on 2026-10-27; a run skipped or
missed at its slot uploads nothing. Then it:

1. **Builds the machine's system** from its flake, `nixosConfigurations.<name>`, keeping the last
   one built under `/var/lib/machine/cache-systems/` as a root, with git on the run's PATH, as Nix
   runs git to fetch a `git+ssh` flake; a private one is reached by the key that
   `machine.upgrade.keyFile` names, so a builder sets it as its own upgrade does. A machine already
   running it ends the run: at `pending/<name>` its pointer is deleted, so an older pointer cannot
   take it back, and at `pending/<name>/<builder>` a confirming pointer naming that path is
   written. One that cannot be asked fails the run with nothing uploaded, as whether it needs the
   system is unknown.
2. **Asks upstream for the closure**, `machine.cache.builder.upstream`, `https://cache.nixos.org`
   by default, below. The paths it lacks are the run's own set; an upstream not reached, or not
   answering for exactly the closure, fails the run with nothing published.
3. **Measures the bucket once**, `rclone size --fast-list`, its one bucket-wide call, 3.3 s on one
   builder on 2026-10-27: over `machine.cache.builder.cap`, 5 GB by default, it uploads nothing,
   writes no pointer, and fails the unit with a line naming the total, decided by the author on
   2026-10-27. The run's own set is not added to the total, so one run, or a few at once, may pass
   the cap by what they upload, and the total lags what was just uploaded, both accepted.
4. **Signs the closure into a directory**, `nix copy` to a `file://` store with the builder's Nix
   key, zstd compressed, and takes from it the narinfo and the NAR of each path of its own set.
5. **Uploads its own set** under its prefix, `pending/<name>` with one unnamed builder and
   `pending/<name>/<builder>` otherwise: the old pointer and its signature deleted first, then the
   NARs, then the narinfos, then the signature and the pointer last, so a
   pointer always has its objects and a narinfo its NAR, even after an interrupted upload.

## Build work on the data disk

**A builder can set `machine.cache.builder.data = true`**, off by default. The author decided on
2026-10-26 that build work belongs on `/data`: a small machine has only a few hundred MB free on
its root filesystem, and one evaluation fetched 918 MB of flake inputs into the main store that
day. Moving `TMPDIR` alone does not move those inputs. The option requires an enabled builder
and a btrfs `/data` mount; a missing mount fails evaluation with the reason. A builder with
its own upgrade flake must select `machine.cache.builder.self` so its own builds also use the run's
storage and cleanup; leaving NixOS's separate automatic build unit enabled fails evaluation.

The author decided on 2026-10-26 that a builder's own system would build in the main store with
its staging on `/data`.
Amended by the author on 2026-10-27: **a builder evaluates and builds its own system in the chroot
store at `/data/build/root`, as for other machines, then copies only its toplevel's closure into
the main store before switching, and reclaims the chroot store while keeping its rooted systems.**
The sandbox's writable `/tmp` must also stay off the small root filesystem. This runs on the host;
a nested Nix sandbox in a container needs privilege such as `CAP_SYS_ADMIN`, and an upgrade must
work even when containerd or the driver is broken.

`machine-cache-build-store` requires `/data` and runs before the scheduled, immediate and self
build units and the Nix daemon. It creates `/data/build` as a subvolume when absent, reapplies
`btrfs qgroup limit 10000000000 /data/build`, and creates its directories without replacing any
existing data. An ordinary directory at `/data/build` fails preparation rather than silently
bypassing the subvolume. `system/boot/disk.nix` already makes `/data` with simple quotas at
installation. Preparation never enables quotas, changes their mode or rescans them. The limit is
10 GB in decimal bytes, shared by the store, caches and scratch work. The locked
[btrfs-progs 6.19.1 package](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/pkgs/by-name/bt/btrfs-progs/package.nix)
provides the [qgroup limit command](https://github.com/kdave/btrfs-progs/blob/v6.19.1/Documentation/btrfs-qgroup.rst)
and documents [simple quota accounting](https://github.com/kdave/btrfs-progs/blob/v6.19.1/Documentation/btrfs-quota.rst).

### Existing directory migration

Before enabling `machine.cache.builder.data` over an ordinary `/data/build` directory, including
one containing `/data/build/tmp` from an interim tmpfiles rule, an operator must:

1. Stop the cache timers and all scheduled, immediate and self build units. Wait for their runs
   and cleanup to finish, and keep them stopped through the migration.
2. With `/data` mounted, move the entire interim `/data/build` directory aside on that filesystem
   to an unused path, such as `/data/build-interim`. Keep its contents for inspection; do not
   delete them or move them onto the root filesystem.
3. Run the preparation from the incoming configuration, letting it create the now absent
   `/data/build` subvolume, its directories and the quota. Confirm preparation succeeds.
4. Switch to the configuration enabling the option, removing the deployment's interim tmpfiles
   rule in that rollout, and resume the cache timers.

This is an operator rollout step. Preparation refuses an existing path that is not a subvolume,
points to these steps, and never deletes or replaces it. Keep the moved directory until its
contents are no longer needed; it is outside the new subvolume's quota and cleanup.

| Setting                                                       | What stays on `/data`                                                                                                                                                               |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `machine.cache.builder.store = "local?root=/data/build/root"` | Every machine's outputs, including the builder's own, fetched sources, derivations, store database and store logs. The option supplies this default and rejects another store.      |
| `--eval-store local?root=/data/build/root`                    | Flake inputs and derivations from both the immediate run's evaluation and the build's evaluation, including self evaluation.                                                        |
| `nix.settings.build-dir = "/data/build/builds"`               | Derivations' build directories, exposed as `/build` inside Linux sandboxes, including daemon builds. It does not move the sandbox root or `/tmp`. The host directory has mode 0755. |
| `XDG_CACHE_HOME=/data/build/cache`                            | Flake evaluation and fetcher databases, git repositories and tarball caches for every build unit and the daemon.                                                                    |
| `TMPDIR=/data/build/tmp`                                      | A run's temporary files and its signed binary cache staging. The directory has mode 0700.                                                                                           |
| Daemon `TMPDIR=/data/build/daemon-tmp`                        | Daemon scratch files, separate from the directory a completed cache run empties.                                                                                                    |
| `NIX_LOG_DIR=/data/build/log`                                 | Main-store derivation logs for daemon builds. All cache runs, including self builds, keep their store logs under `/data/build/root/nix/var/log/nix`.                                |
| `RequiresMountsFor=/data` and the preparation dependency      | A missing data disk stops every build unit and the daemon before they can write beneath an unmounted `/data` on the root filesystem.                                                |

The flake's
[locked nixpkgs revision selects Nix 2.34.9](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/pkgs/tools/package-management/nix/default.nix).
Its [local store manual](https://nix.dev/manual/nix/2.34/store/types/local-store) describes the
physical store under the chroot root and the per-store `build-dir`. The
[global setting](https://nix.dev/manual/nix/2.34/command-ref/conf-file#conf-build-dir) overrides
that setting for every local store. At the exact locked version,
[local-store.hh](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/local-store.hh)
says the daemon's setting applies to daemon builds, and
[local-settings.hh](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/local-settings.hh)
defines the global override. Client environment alone cannot move daemon build directories.

**Evaluation follows the selected store in Nix 2.34.9**, even without an explicit evaluation
flag: [EvalCommand::getEvalStore](https://github.com/NixOS/nix/blob/2.34.9/src/libcmd/command.cc)
defaults to `getStore()`. With the data option enabled, every run states `--eval-store` explicitly
and uses the same chroot store for evaluation and building.
Its [flag definition](https://github.com/NixOS/nix/blob/2.34.9/src/libcmd/common-eval-args.cc)
covers derivations and their inputs;
[InstallableFlake](https://github.com/NixOS/nix/blob/2.34.9/src/libcmd/installable-flake.cc)
locks the flake through that evaluation state. This keeps fetched evaluation sources in the
chroot store as well as moving the fetcher caches. The cache location comes from
[users.cc](https://github.com/NixOS/nix/blob/2.34.9/src/libutil/users.cc), used by the
[fetcher database](https://github.com/NixOS/nix/blob/2.34.9/src/libfetchers/cache.cc),
[git cache](https://github.com/NixOS/nix/blob/2.34.9/src/libfetchers/git.cc) and
[tarball cache](https://github.com/NixOS/nix/blob/2.34.9/src/libfetchers/git-utils.cc).

**A self build uses the chroot store for both evaluation and building.** Before switching, the run
sets the system profile with
`nix-env --option substituters 'local?root=/data/build/root&trusted=true' -p /nix/var/nix/profiles/system --set <toplevel>`,
which brings the toplevel's closure into the main store and roots it in one process. In 2.34.9,
[opSet](https://github.com/NixOS/nix/blob/2.34.9/src/nix/nix-env/nix-env.cc#L758-L801) realises the store path with `buildPaths` and then
calls [createGeneration](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/profiles.cc#L64-L99), whose
[addPermRoot](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/indirect-root-store.cc#L18-L43) registers the generation link as a
permanent root in the main store. Each
[substitution goal](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/build/substitution-goal.cc#L29-L38) first registers a temporary
root for its path, skips a path the main store already holds and
[substitutes every reference first](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/build/substitution-goal.cc#L126-L132), so only
the missing paths of that closure move. A temporary root lives while its process holds its
[temporary roots file](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/gc.cc#L48-L155) locked, and
[findTempRoots](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/gc.cc#L157-L195) drops a file only once its process is gone. A
collection already running learns of each new temporary root through its socket. A separate `nix copy`
would lose its temporary roots on exit, leaving the copied system unrooted until the profile
command started, so a collection in that gap could delete it. As root the command opens the main
store directly, by the [`auto` store](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/store-registration.cc#L33-L35) for a writable
state directory, so these roots are the main store's own.

**The signature exemption covers the chroot store as a source alone.** The option replaces the
substituter list for that one command, so the main store's configured caches are neither queried
nor trusted there. `trusted=true` is the chroot store reference's own
[`trusted` setting](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/store-api.hh#L207-L216): the substitution goal
waives the [signature requirement](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/local-store.cc#L975-L978) only for a substituter
that sets it ([lines 116 to 122](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/build/substitution-goal.cc#L116-L122)) and copies
from that substituter alone without checking signatures
([line 228](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/build/substitution-goal.cc#L228)). Outputs built locally in the chroot
store carry no signature, which is why it needs the exemption. The main store keeps `require-sigs`
and its `trusted-public-keys` for every other source, and the module sets neither. A failed build
or profile command exits before the switch runs and leaves the profile unchanged; cleanup still
collects the chroot store and keeps its rooted systems. The upload still signs the binary cache
with the configured key.

A self run uploads nothing, RFC ttcli. Another machine's upload reads from the chroot store, where
the build completed the entire closure, and the run's system root and lock protect it through
upload and cleanup. With `machine.cache.builder.data = false`, every run, including self, uses an
explicitly configured `machine.cache.builder.store` for its build, and another machine's run for
its closure query and upload too, without the data option's substituter or reclamation.

**The self build's sandbox and writable `/tmp` are on `/data`.** In 2.34.9,
[ChrootDerivationBuilder::prepareSandbox](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/unix/build/chroot-derivation-builder.cc)
creates `<physical-store>/<derivation>.chroot/root` and its writable `tmp` directory. For a self
build that is `/data/build/root/nix/store/<derivation>.chroot/root/tmp`. A derivation writing
hundreds of MB to `/tmp` writes to the data disk, and sandbox outputs start there too.
[The Unix builder](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/unix/build/derivation-builder.cc)
uses `build-dir` for a separate temporary build directory, and the
[Linux builder](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/unix/build/linux-derivation-builder.cc)
bind mounts that directory into the sandbox as `/build`. Neither `build-dir` nor the run's `TMPDIR`
relocates the sandbox root or its `/tmp`; selecting the chroot build store puts both under
`/data/build/root` for every machine, including self.

The local store's
[`log` setting](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/local-fs-store.hh)
defaults, without a chroot root, through
[getDefaultLogDir](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/local-fs-store.cc) to
[`NIX_LOG_DIR`](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/globals.cc).
[LogFile](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/build/derivation-building-goal.cc)
writes derivation logs beneath that directory's `drvs`, normally `/nix/var/log/nix/drvs`.
The option sets `NIX_LOG_DIR` for every build unit and the daemon to keep these logs on `/data`.

The main store grows only by paths of the self system's closure that it does not already hold.
A live builder must measure the root's used space before and after a self build and confirm the
growth is about those new paths alone, with no sandbox directory on the root during the build.

**Kept systems remain rooted across collection.**
[`nix build`](https://github.com/NixOS/nix/blob/2.34.9/src/nix/build.cc) registers its out-links
before returning, as the [build manual](https://nix.dev/manual/nix/2.34/command-ref/new-cli/nix3-build) describes.
[createOutLinks](https://github.com/NixOS/nix/blob/2.34.9/src/libcmd/command.cc) calls
[addPermRoot](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/indirect-root-store.cc) for the
run's `/var/lib/machine/cache-systems/<name>` link. It creates the link to the logical store path,
then [addIndirectRoot](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/gc.cc) records it at
`/data/build/root/nix/var/nix/gcroots/auto/<hash>`. The same file's `findRootsNoTemp` scans that
store's `gcroots`, follows the indirect link and checks the path against that store's validity
database. The external link can therefore protect a path absent from the main store. The store's
[state directory definition](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/include/nix/store/local-fs-store.hh)
prefixes the chroot root to `nix/var/nix`, while the
[local filesystem accessor](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/local-fs-store.cc)
reads the physical store under that root.

The run takes `/run/lock/machine-cache` before evaluation and holds it through cleanup. The old
system's permanent root stays throughout the build; Nix holds temporary roots during the build
and registers the replacement out-link before returning. Every later periodic collector must take
this same lock before collecting, so collection cannot meet the gap between evaluation and build
or the handoff between Nix processes. Permanent system links are kept after the run ends.

On success, failure or `SIGTERM`, cleanup empties `/data/build/tmp`, including hidden files and
staging, and runs `nix store gc` against the chroot store with `keep-derivations` and `keep-outputs`
false. The collector keeps the rooted system closures and removes unrooted intermediates and
fetched evaluation sources. It never wipes the store, removes system roots or collects the main
store. A cleanup failure makes the unit fail while preserving its reported outcome. A process
killed with `SIGKILL` cannot run an exit trap; the later collector must also take the run lock.

`tests/build/run-test.sh` uses Nix from the locked input and a disposable real chroot store to
prove a new system is rooted by the run's actual out-link after success, and the previous system
survives build failure, `SIGTERM` and a failed self build while unrooted paths are collected. A
failed self profile command retains the newly rooted system in the chroot store and never switches,
while cleanup still reclaims unrooted paths and temporary files. Its `self-gc` mode runs the real
profile command against a disposable main store with signatures required, collects that store
right before and right after it, and checks that the self system and its reference stay valid and
rooted by the profile; with the earlier copy the collection deleted both. Its
setup creates no roots; an initial successful run roots the previous system. It checks the
evaluation and build flags and the lock during building and collection, and that a failed
collection fails the run while keeping its outcome. `tests/build/self-test.sh` checks an explicit
store with data mode off, the chroot build and evaluation flags, the profile command substituting
from the trusted chroot store before switching, and no closure query or upload before collection.
The module tests check both Linux architectures and rehearse preparation twice with a command
substitute for btrfs. A live builder must still establish the quota's effect on a full build,
the daemon's build directory in actual use and the bytes reclaimed after a real run. No machine
is switched by these tests. This option replaces the deployment's interim environment, mount and
tmpfiles additions; their removal belongs to the deployment's own change.

## Exactly the paths upstream lacks, RFC ttcli

**A run's own set is what upstream lacks of the closure**, decided by the author on 2026-10-27:
the paths built from a deployment's own sources, its driver, the machine's modules and its
generated configuration, which is how this carries out RFC mgzfp's "the bucket only our own".
Local signatures decide nothing, as most paths built in the `/data` chroot store lose every
signature on the way, RFC ttcli. The whole closure is asked in one
`nix path-info --store <upstream> --option narinfo-cache-meta-ttl 0 --json --json-format 1 --stdin`,
and a path upstream lacks is `null` in its answer. In the Nix the flake locks, 2.34.9, that command
asks every path at once on `queryMissing`'s thread pool
([misc.cc:107](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/misc.cc#L107)), not
`Store::queryValidPaths`, whose pool `nix copy` uses
([store-api.cc:763-808](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/store-api.cc#L763-L808)),
and then reads each path's info in series, which `queryPathInfo` answers from the local
`NarInfoDiskCache` first and writes back
([store-api.cc:608-678](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/store-api.cc#L608-L678)).
On one builder on 2026-10-27, 720 paths took 1 s.

**A run that cannot ask upstream fails closed**, provisional, recommended by the integrator on
2026-10-27: no NAR, no narinfo, no pointer, the old pointer kept, and the outcome `failed` with a
line naming upstream. `nix path-info` turns only a missing path into `null`
([path-info.cc:88-89](https://github.com/NixOS/nix/blob/2.34.9/src/nix/path-info.cc#L88-L89)) and
fails on any other error, and the run also refuses an answer whose paths are not the closure's.
Nix's HTTP store reads a 403 as a 404
([http-binary-cache-store.cc:130](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/http-binary-cache-store.cc#L130)),
so `narinfo-cache-meta-ttl` at 0 has it fetch `nix-cache-info` on every run, which fails on
anything but a binary cache that answers
([http-binary-cache-store.cc:62-80](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/http-binary-cache-store.cc#L62-L80),
[262-273](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/http-binary-cache-store.cc#L262-L273)),
and **every path Nix calls missing is asked again**, provisional, chosen by the advisor on
2026-10-27, as a 403 on one narinfo would read as `null` too: one `curl` per such path, sixteen at
once, for `<upstream>/<hash>.narinfo`, the store reference's parameters dropped first as Nix drops
them, redirects followed as Nix follows them, five at most, each try held to 20 s and tried three
times, a refused connection among them. Only a final 404 counts as lacking and a 200 leaves the
path out of the own set; any other code, or a `curl` that fails, fails the run closed with a line
naming upstream and the code.

**Nix uploads no path whose references the store it writes to lacks.** `nix copy --no-recursive`
to a binary cache, and copying each path alone, both stop at Nix's check that every reference is
valid in the destination, tried with Nix 2.35 on 2026-10-25:

```
error: cannot add '/nix/store/...-nix-2.35.3' to the binary cache because the reference
'/nix/store/...-nix-fetchers-2.35.3' is not valid
```

So the whole closure is copied to a directory on the builder, where every reference is present, and
`rclone` copies from it the two objects of each path of the run's own set, `<hash>.narinfo` and the
NAR its `URL:` names, and nothing else. **Every run uploads its whole own set again**, decided by
the author on 2026-10-27, by `rclone copy --no-check-dest`, which neither lists nor compares the
destination, so each object's upload time is the latest run's for the expiry below. `nix copy
--to s3://` is never used, as it skips the paths the bucket holds, `queryValidPaths` on the
destination ([store-api.cc:1026](https://github.com/NixOS/nix/blob/2.34.9/src/libstore/store-api.cc#L1026)).

## The pointer

```json
{ "machine": "<name>", "path": "/nix/store/...-nixos-system-...", "at": "2026-10-25T14:30:00Z" }
```

Signed by `ssh-keygen -Y sign -n machine-cache` with the builder's pointer key, a new one
replacing the old: at `pending/<name>/<builder>` wherever `builds.<name>.builders` names the
machine's builders, and at `pending/<name>` where it is empty, one unnamed builder, as before. The
bucket is the one thing between builder and machine, so the pointer is trusted by its signature
alone, and the paths by their Nix signatures alone: a token that writes the bucket cannot make a
machine run anything.

## The fetched machine

A machine with `machine.cache.fetch.builders` and no builds of its own evaluates nothing: NixOS's
own upgrade is off, and `machine-cache-fetch` runs at `machine.upgrade.at` in its place; a builder
below 4096 MB runs the same fetch from its own run at that time instead, below. `fetch.sh`:

- fetches, with its read-only token, each named builder's pointer at `pending/<name>/<builder>`
  and the one at `pending/<name>`, each with its signature; with none it does nothing;
- verifies each by `ssh-keygen -Y verify -n machine-cache`, a named builder's against that
  builder's key alone and `pending/<name>` against all of them, refuses one written for another
  machine or more than an hour ahead of its clock, and takes the one with the newest `at` that is
  newer than the last it applied, kept in `/var/lib/machine/cache-applied`; an older one is passed
  over, a refused one or a failed read fails the unit where no newer valid one is taken, and no
  newer one for two days fails it too;
- realizes the path from the bucket and the machine's own substituters, upstream, trusting its
  builders' Nix keys and the machine's own trusted keys alone, where the path is not valid already,
  so a confirming pointer fetches nothing; a path no source holds fails the fetch and the machine
  waits for the next run, as a consumer never builds;
- sets the system profile and switches, as the self-upgrade does, a confirming pointer switching
  nothing and recording its `at`. A new kernel waits for a reboot by hand.

**The builder reaches it as the user `machine-cache`**, whose authorized keys are each builder's
access key under `restrict,from=`, the tailnet's addresses, `machine.cache.fetch.from`, and
`command=` the wrapper, `answer.sh`, which answers two things alone: `current`, the current
system's path, and `lacks`, which of the store paths given on stdin are not valid, checked by
`nix-store --check-validity` and nothing written. No run asks `lacks` since RFC ttcli; it stays for
a builder not yet moved against a consumer switched first, provisional, chosen by the advisor on
2026-10-27, and goes once every builder runs the new design. A builder running a
tailnet dials through `tailscale nc`, so it reaches a machine by its name with no resolver.

**A machine's host key is taken on first contact** into `/var/lib/machine/cache-known-hosts` on its
builder, and a reinstalled machine's new key is refused, failing each run for it. Its old entry is
removed on the builder, `ssh-keygen -R <host> -f /var/lib/machine/cache-known-hosts`, and the next
run takes the new key.

## Several builders, RFC dpcnp

**A deployment's inventory derives every builder and every machine it builds**, `lib.fleet` in
this repository's flake, `system/nix/cache/fleet.nix`: each machine's system, memory, time and
overrides in, its `builds`, its `fetch.builders`, its role and its slots out, a priority outside 1
to 3, a missing flake, two slots of one builder closer than a gap or a time differing from
`machine.upgrade.at` failing evaluation with the machine's name.

- **One slot per builder**: a machine's builders laid out by their priorities and, within one,
  by sha256 of its name and the UTC date, the last slot ending a gap before its time. A builder
  runs at its own slot alone, ends where an answer since the machine's first slot or a claim
  younger than a gap less a minute is there, and otherwise writes its claim and builds; a run that
  misses its slot by its lock or by starting after its slot's gap fails its unit, as does the last
  slot when a claim blocks it.
- **A pointer per builder, the newest taken**: the fetch verifies each by its builder's key, takes
  the one with the newest `at` past the last applied, and refuses one more than an hour ahead of its
  clock. A builder that finds the machine already running its system writes a confirming pointer,
  which switches nothing.
- **A builder's own system**: above 4096 MB of memory it builds and switches at its own time and
  publishes nothing, provisional, chosen by the advisor on 2026-10-27, since no fetch and no slot
  reads a builder's own upload; a builder takes its system from another only through the pointer
  that builder's run for it writes. Below 4096 MB, it takes a pointer for itself from the other
  builders first and builds itself where none is newer than its last applied, publishing nothing
  either; a refused pointer or a failed read does not stop it, and the run fails afterwards
  naming each, provisional, chosen by the advisor on 2026-10-26, so the machine has its system and
  the failure is still seen.
- **`/var/lib/machine` keeps systemd's default mode**: the cache's units, the seed's and the
  addresses' share it, so no unit sets a `StateDirectoryMode` for it and secrecy comes per file
  through `UMask`, which `system/network/addresses/eval-test.nix` checks.

## A run's outcome, the interface `upgrade` reads

**Every run prints one line as its last**, provisional, chosen by the advisor on 2026-10-26, so a
deployment's tooling reads what happened from the unit's journal and never from its prose:

```
machine-cache outcome=<outcome> consumer=<machine> [self=<built|fetched|failed>]
```

`outcome` is what the run did for the consumer: `built`, a system built and its pointer published,
or for a `--self` run, its system built and switched; `answered`, a fresh
answer already there; `claimed`, a builder's claim, which may be the run's own, younger than a gap
less a minute; `confirmed`, the machine already running it; `missed`, its slot lost to the lock or a
late start; `skipped`, a timer run at another builder's slot; `failed`, anything else. `self`, on a
builder's own run alone, is what became of its own system, so a builder that switched and then could
not record it prints `outcome=failed` with `self=built`. Cleanup preserves that outcome,
but a cleanup failure makes the exit status nonzero. The words change only with a version, and no
other line begins `machine-cache outcome=`; `tests/outcome-test.sh` holds every exit path to it.

## The bucket and its credentials

**The bucket holds the pointers and their signatures, the claims, `nix-cache-info` and each run's
own set, and the only thing that deletes from it is its lifecycle rule**, RFC ttcli, decided by the
author on 2026-10-27: every object deleted one day after its upload, applied by the integrator at
rollout. R2 deletes typically within 24 hours of expiry, so an object lives one to two days. No run
lists the bucket, its size for the cap aside, or deletes an object but its own old pointer, and
`nix-cache-info` is uploaded first by every run for another machine that takes its lock, a
confirming one included, so it never expires while those runs go on. A machine off for more than a
day finds its pointer expired and takes its system from the next daily run, an accepted consequence.
Every machine asks a substituter again soon, `narinfo-cache-positive-ttl = 3600` and
`narinfo-cache-negative-ttl = 60` in `system/nix/default.nix`, provisional, chosen by the advisor on
2026-10-27, so an expired path, or one uploaded after an earlier miss, is not trusted from a stale
local answer for long. The fetch's own realization sets `narinfo-cache-negative-ttl` to 0 for
itself, so the one command that takes the system trusts no cached miss at all, and the 60 holds for
every other command on the machine.

`machine.cache.bucket` names the bucket; `machine.cache.credentials` is an environment file holding
its endpoint, `MACHINE_CACHE_ENDPOINT`, and the token reaching it, `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`, read and written by `rclone` on a builder, read by `curl --aws-sigv4` and
Nix's `s3://` store on a fetched machine. **The endpoint is its URL as the provider's dashboard
shows it**, `https://<account id>.r2.cloudflarestorage.com` pasted whole, or its host alone.
`endpoint.sh` reads it for both scripts: the spaces and newlines around it are dropped, then one
trailing `/`, then one path that is `/<bucket>` alone, as the bucket's own page shows it, then the
scheme `https`, in any case. What is left must be a host of letters, digits, dots and hyphens, with
`:` and a port at most; anything else, another scheme, any other path, a query, a fragment, a user
or a space inside it, is refused, the variable named and never its value. `rclone` and `curl` are
given `https://` and the host, and Nix's store the host with `scheme=https`, the form Nix's manual
shows for an S3-compatible store, https://nix.dev/manual/nix/2.34/store/types/s3-binary-cache-store.
A builder holds three more keys, each a file: `signingKey`, the Nix secret key; `pointerKey`, the
SSH key signing pointers; and `accessKey`, the SSH key reaching the wrapper.

**Verify runs the cache's tests**, listed in `scripts/verify/tests.res` beside the rest: the endpoint's forms, the protocol of slots, claims
and pointers, delivery with a bucket under the cap uploading and one past it uploading nothing, the
lock, the own system publishing nothing, the inventory's derivation and the module's units against
a directory with `rclone` and `ssh` faked, the directory's size summed over its files as `rclone
size` sums a local remote, and the legacy layout against a fixture recorded
from the one-builder code, `tests/fixtures/legacy-layout.json`; and that the run as built holds git
on its PATH, which a live `git+ssh` flake needed on 2026-10-26. The tests under `tests/upload/`
cover the own set against a fake upstream, by Nix from the locked input against a `file://` cache
and through whole runs; every key uploaded again where the bucket holds it, with no listing; the
order of `nix-cache-info` first, a confirming run included, then NARs, narinfos and the pointer
last; an upstream not reached, answering for other paths or answering 403 for one narinfo
publishing nothing; retry after an interruption between upload passes; and both upload list read
errors.

**On a test machine** an absolute path stands a directory in for the bucket, with no credentials,
and `machine.cache.builder.store` builds in a store of another root, so a machine building its own
system does not hold what it builds and lacks what a fetched machine would. The local machine
proved the whole path so on 2026-10-25.
