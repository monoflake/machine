# The cache

How a machine too small to evaluate its own system takes its daily upgrade, `system/nix/cache/`,
built for monoflake/cloud's RFC u9fxz and its amendment, RFC dpcnp: a builder evaluates and builds
the machine's system, uploads only what the machine lacks to a bucket on Cloudflare R2, and writes
a signed pointer to it; the machine fetches the pointer, takes the paths, and switches.
`machine.cache` in `system/options.nix` sets both roles, and `machine.cache.enable` turns them on
once the bucket and its keys exist.

## A builder's run

A machine named in `machine.cache.builds` gets a unit `machine-cache-<name>` on its builder. With
one unnamed builder, `builds.<name>.builders` empty, it is timed at its `at` or started by hand
where `at` is null, as on a fallback builder; with a deployment's inventory it fires at each of the
machine's slots and runs at the builder's own alone, below. `machine-cache-now@<name>` starts the
same run at once, skipping the wait for its slot but not the check for a fresh answer. A run missed
while the builder was off is skipped, never caught up. **A builder's runs never overlap**: each
holds `/run/lock/machine-cache` by `flock`, so no two evaluations meet in its memory, no two sweeps
meet, and the cap is measured by one run at a time. A run, `run.sh`, for its one machine:

1. **Sweeps the bucket.** A pointer at `pending/<name>` whose machine runs its path, asked by
   `current`, is deleted with its signature and its delta; a pointer of this builder at
   `pending/<name>/<builder>` is retired once the machine reports a newer one applied, asked by
   `applied`. Then every object is deleted that no pending delta names, that the newest pointer of
   none of this builder's machines needs, that no builder's self marker needs, and that is older
   than two hours; `nix-cache-info`, `pending/` and `self/` are kept. The objects are listed before
   the deltas and markers are read, and a run writes its delta before its objects, so another
   builder's delivery meanwhile is kept by its delta, and a self upload before its marker by its
   age. A machine with no pointer is passed over,
   since `rclone cat` of a missing R2 object prints nothing and exits 0, seen on 2026-10-26; a
   pointer whose machine cannot be asked is kept, a line saying so.
2. **Builds the machine's system** from its flake, `nixosConfigurations.<name>`, keeping the last
   one built under `/var/lib/machine/cache-systems/` as a root, with git on the run's PATH, as Nix
   runs git to fetch a `git+ssh` flake; a private one is reached by the key that
   `machine.upgrade.keyFile` names, so a builder sets it as its own upgrade does. A machine already
   running it ends the run: at `pending/<name>` its pointer and delta are deleted, so an older
   pointer cannot take it back, and at `pending/<name>/<builder>` a confirming pointer naming that
   path is written with no delta. One that cannot be asked fails the run with nothing uploaded, as
   whether it needs the system is unknown.
3. **Asks the machine which paths of the closure it lacks**, through its wrapper below, and fails
   where the answer names a path outside the closure.
4. **Signs the closure into a directory**, `nix copy` to a `file://` store with the builder's Nix
   key, zstd compressed, and takes from it the narinfo and the NAR of each path the machine lacks.
5. **Measures the bucket**: where what it holds and what the delta adds pass
   `machine.cache.builder.cap`, 8 GB by default, it uploads nothing, writes no pointer, and fails
   the unit. The cap is provisional, chosen by the advisor on 2026-10-26.
6. **Uploads the delta** under its prefix, `pending/<name>` with one unnamed builder and
   `pending/<name>/<builder>` otherwise: the old pointer deleted first, the delta's list written as
   `<prefix>.objects`, the objects copied, then the signature and the pointer last, so a pointer
   always has its objects.

## Exactly the paths the machine lacks

**Nix uploads no path whose references the store it writes to lacks.** `nix copy --no-recursive`
to a binary cache, and copying each path alone, both stop at Nix's check that every reference is
valid in the destination, tried with Nix 2.35 on 2026-10-25:

```
error: cannot add '/nix/store/...-nix-2.35.3' to the binary cache because the reference
'/nix/store/...-nix-fetchers-2.35.3' is not valid
```

So the whole closure is copied to a directory on the builder, where every reference is present, and
`rclone` copies from it the two objects of each path the machine lacks, `<hash>.narinfo` and the
NAR its `URL:` names, and nothing else. The machine takes them as a substituter: Nix substitutes a
path's references before the path, and a reference the machine holds is valid already, so it never
asks the bucket for one.

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
- realizes the path from the bucket as its only substituter, trusting its builders' Nix keys alone,
  where the path is not valid already, so a confirming pointer fetches nothing;
- sets the system profile and switches, as the self-upgrade does, a confirming pointer switching
  nothing and recording its `at`. A new kernel waits for a reboot by hand.

**The builder reaches it as the user `machine-cache`**, whose authorized keys are each builder's
access key under `restrict,from=`, the tailnet's addresses, `machine.cache.fetch.from`, and
`command=` the wrapper, `answer.sh`, which answers three things alone: `current`, the current
system's path, `applied`, the last pointer applied from `/var/lib/machine/cache-applied`, and
`lacks`, which of the store paths given on stdin are not valid, checked by
`nix-store --check-validity` and nothing written. A builder running a tailnet dials through
`tailscale nc`, so it reaches a machine by its name with no resolver.

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
  uploads what the cache lacks. Its newest self upload is kept through its closure, including
  paths uploaded on earlier days, so an unchanged system uploads no paths again, decided by the
  author on 2026-10-26. A completed build, switch and upload replaces `self/<builder>` last; a run
  that fetched its system leaves the old marker alone, provisional, chosen by the advisor on
  2026-10-26. Below 4096 MB, it takes a pointer for itself from the other builders first
  and builds itself where none is newer than its last applied; a refused pointer or a failed read
  does not stop it, and the run fails afterwards naming each, provisional, chosen by the advisor on
  2026-10-26, so the machine has its system and the failure is still seen.
- **The sweep**, step 1 above, walks the newest pointers of the sweeping builder's own machines;
  another machine's objects are kept by its delta. Every builder's sweep also reads every
  builder's self marker and follows its path's references with `protect_path`, exactly as for the
  newest pointer. Only the replacement marker's closure counts for that builder; objects it no
  longer needs expire after two hours unless another marker, pointer or delta keeps them, and
  markers themselves never expire by age, provisional, chosen by the advisor on 2026-10-26.
  If a listed marker or any narinfo in its closure cannot be read, the sweep deletes nothing;
  the run still builds and uploads, names the refusal on stderr and exits nonzero while keeping
  its outcome, provisional, chosen by the advisor on 2026-10-26. The deferred `cache-rest` race
  between two builders' sweeps covers markers too, so a sweep can delete an object a newer marker
  reuses.
  A builder retires its own older pointers once the machine reports a newer one applied, and one
  at `pending/<name>` once the machine runs its path.
  An expired path's narinfo is deleted before its NAR. Every narinfo that remains, whether kept
  by a marker, pointer, delta, age or a failed deletion, keeps its NAR even when another path
  shares it; an old NAR with no remaining narinfo still expires, provisional, chosen by the
  advisor on 2026-10-26.
- **`/var/lib/machine` keeps systemd's default mode**: the cache's units, the seed's and the
  addresses' share it, and the user `machine-cache` reads `cache-applied` there, so no unit sets a
  `StateDirectoryMode` for it and secrecy comes per file through `UMask`, which
  `system/network/addresses/eval-test.nix` checks.

## A run's outcome, the interface `upgrade` reads

**Every run prints one line as its last**, provisional, chosen by the advisor on 2026-10-26, so a
deployment's tooling reads what happened from the unit's journal and never from its prose:

```
machine-cache outcome=<outcome> consumer=<machine> [self=<built|fetched|failed>]
```

`outcome` is what the run did for the consumer: `built`, a system built and its pointer published,
or for a `--self` run, its system built, switched and its lacking paths uploaded; `answered`, a fresh
answer already there; `claimed`, a builder's claim, which may be the run's own, younger than a gap
less a minute; `confirmed`, the machine already running it; `missed`, its slot lost to the lock or a
late start; `skipped`, a timer run at another builder's slot; `failed`, anything else. `self`, on a
builder's own run alone, is what became of its own system, so a builder that switched and then could
not record it or upload prints `outcome=failed` with `self=built`. Cleanup preserves that outcome,
but a cleanup failure makes the exit status nonzero. The words change only with a version, and no
other line begins `machine-cache outcome=`; `tests/outcome-test.sh` holds every exit path to it.

## The bucket and its credentials

**A self marker lives at `self/<builder>`**, one object per builder replacing its predecessor,
provisional, chosen by the advisor on 2026-10-26. Its JSON has the pointer's `path` and `at`:

```json
{ "path": "/nix/store/...-nixos-system-...", "at": "2026-10-26T14:00:00Z" }
```

The separate `self/` prefix keeps markers outside the consumer pointers at `pending/<name>` and
`pending/<name>/<builder>`. Fetch, slot and the sweep's pointer loop cannot take one as a pointer,
which `pending/<builder>/self` would allow. A marker is an unsigned retention record with no
consumer `machine`, signature or delta list; Nix signatures still govern substituted paths,
provisional, chosen by the advisor on 2026-10-26. Every object other than narinfo files is uploaded
in a first pass, then the narinfo files in a second, and the marker last, so a narinfo always has
its NAR even after an interrupted upload, provisional, chosen by the advisor on 2026-10-26.
Both pass lists must be read successfully before delta publication or object upload; an empty
list is allowed, but a read error fails the run and keeps the old marker, provisional, chosen by
the advisor on 2026-10-26.
Objects still present and `nix-cache-info` already present are not uploaded again, provisional,
chosen by the advisor on 2026-10-26. A repeated build refreshes the marker's `at` while leaving
the closure objects unchanged.

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

**Verify runs the cache's tests**, `tests.sh`: the endpoint's forms, the sweep, the protocol of
slots, claims and pointers, delivery, the lock, the own system, the inventory's derivation and the
module's units against a directory with `rclone` and `ssh` faked, and the legacy layout against a
fixture recorded from the one-builder code, `tests/fixtures/legacy-layout.json`; and that the run as
built holds git on its PATH, which a live `git+ssh` flake needed on 2026-10-26. The tests under
`tests/self-marker/` cover marked references surviving a daily sweep, unmarked and superseded
uploads expiring, a repeated self build uploading no closure objects, publication order, keeping
the old marker after a fetch or upload failure, refusal of all deletion on a marker or marked
narinfo read failure with a visible run failure, retry after an interruption between upload
passes, both upload list read errors, narinfo deletion failures, shared and orphan NARs, and
isolation from all three pointer readers.

**On a test machine** an absolute path stands a directory in for the bucket, with no credentials,
and `machine.cache.builder.store` builds in a store of another root, so a machine building its own
system does not hold what it builds and lacks what a fetched machine would. The local machine
proved the whole path so on 2026-10-25.
