# The cache

How a machine too small to evaluate its own system takes its daily upgrade, `system/nix/cache/`,
built for monoflake/cloud's RFC u9fxz: a builder evaluates and builds the machine's system, uploads
only what the machine lacks to a bucket on Cloudflare R2, and writes a signed pointer to it; the
machine fetches the pointer, takes the paths, and switches. `machine.cache` in `system/options.nix`
sets both roles, and `machine.cache.enable` turns them on once the bucket and its keys exist.

## A builder's run

A machine named in `machine.cache.builds` gets a unit `machine-cache-<name>` on its builder, timed
at its `at`, an hour before that machine's own upgrade, or started by hand where `at` is null, as
on a fallback builder. A run missed while the builder was off is skipped, never caught up, and
its machine takes nothing that day. **A builder's runs never overlap**: each holds
`/run/lock/machine-cache` by `flock`, so no two evaluations meet in its memory, no two sweeps meet,
and the cap is measured by one run at a time. A run, `run.sh`, for its one machine:

1. **Sweeps the bucket.** A pointer of a machine built here whose machine already runs its path is
   deleted with its signature and its delta; then every object no pending delta names is deleted,
   `nix-cache-info` and the pointers kept. The objects are listed before the deltas are read, and a
   run writes its delta before its objects, so what a fallback builder uploads meanwhile is kept.
   A machine with no pointer is passed over, since `rclone cat` of a missing R2 object prints
   nothing and exits 0, seen on 2026-10-26; a pointer that names no path is passed over with a line
   saying so; one whose machine cannot be asked what it runs is kept, a line saying so. Only an
   answer equal to the path deletes it.
2. **Builds the machine's system** from its flake, `nixosConfigurations.<name>`, keeping the last
   one built under `/var/lib/machine/cache-systems/` as a root, with git on the run's PATH, as Nix
   runs git to fetch a `git+ssh` flake; a private one is reached by the key that
   `machine.upgrade.keyFile` names, so a builder sets it as its own upgrade does. A machine already
   running it ends the run, its pointer and delta deleted, so an older pointer cannot take it back;
   one that cannot be asked fails the run with nothing uploaded, as whether it needs the system is
   unknown.
3. **Asks the machine which paths of the closure it lacks**, through its wrapper below, and fails
   where the answer names a path outside the closure.
4. **Signs the closure into a directory**, `nix copy` to a `file://` store with the builder's Nix
   key, zstd compressed, and takes from it the narinfo and the NAR of each path the machine lacks.
5. **Measures the bucket**: where what it holds and what the delta adds pass
   `machine.cache.builder.cap`, 5 GB by default, it uploads nothing, writes no pointer, and fails
   the unit.
6. **Uploads the delta**: the old pointer deleted, the delta's list written as
   `pending/<name>.objects`, the objects copied, then the pointer `pending/<name>` and its signature
   `pending/<name>.sig` last, so a pointer always has its objects.

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

Signed by `ssh-keygen -Y sign -n machine-cache` with the builder's pointer key, one per machine, a
new one replacing the old. The bucket is the one thing between builder and machine, so the pointer
is trusted by its signature alone, and the paths by their Nix signatures alone: a token that writes
the bucket cannot make a machine run anything.

## The fetched machine

A machine with `machine.cache.fetch.builders` evaluates nothing: NixOS's own upgrade is off, and
`machine-cache-fetch` runs at `machine.upgrade.at` in its place, `fetch.sh`:

- fetches `pending/<its name>` and its signature with its read-only token, and with no pointer does
  nothing;
- verifies it by `ssh-keygen -Y verify -n machine-cache` against an `allowed_signers` naming each
  builder's pointer key, and refuses a pointer written for another machine, or whose `at` is
  earlier than the last one it applied, kept in `/var/lib/machine/cache-applied`; one already
  applied is nothing to do;
- realizes the path from the bucket as its only substituter, trusting its builders' Nix keys alone;
- sets the system profile and switches, as the self-upgrade does. A new kernel waits for a reboot by
  hand.

**The builder reaches it as the user `machine-cache`**, whose authorized keys are each builder's
access key under `restrict,from=`, the tailnet's addresses, `machine.cache.fetch.from`, and
`command=` the wrapper, `answer.sh`, which answers two things alone: `current`, the current
system's path, and `lacks`, which of the store paths given on stdin are not valid, checked by
`nix-store --check-validity` and nothing written. A builder running a tailnet dials through
`tailscale nc`, so it reaches a machine by its name with no resolver.

**A machine's host key is taken on first contact** into `/var/lib/machine/cache-known-hosts` on its
builder, and a reinstalled machine's new key is refused, failing each run for it. Its old entry is
removed on the builder, `ssh-keygen -R <host> -f /var/lib/machine/cache-known-hosts`, and the next
run takes the new key.

## The bucket and its credentials

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

**Verify runs the cache's tests**: `endpoint-test.sh` the endpoint's forms, `sweep-test.sh` the
sweep against a directory with `rclone` and `ssh` faked, and `build-test.sh` that the run as built
holds git on its PATH, which a test machine's `path:` flake never needed and a live `git+ssh` one
did, on 2026-10-26.

**On a test machine** an absolute path stands a directory in for the bucket, with no credentials,
and `machine.cache.builder.store` builds in a store of another root, so a machine building its own
system does not hold what it builds and lacks what a fetched machine would. The local machine
proved the whole path so on 2026-10-25.
