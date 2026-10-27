---
name: 'Only What Upstream Lacks'
title: 'A run uploads only the paths of its closure upstream lacks, all of them again each day, and the bucket deletes by its lifecycle rule alone'
status: accepted
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

A builder's run took about 50 minutes, measured on 2026-10-27 on one builder, read only, and most
of it was spent on the bucket rather than on building. The bucket held 2872 objects, 1.52 GiB, 1485
of them narinfo. One `rclone lsjson -R` of it took 421.7 s, and a run listed it three times, for
the sweep, the `.objects` deltas and the cap; one `rclone cat` of a narinfo took 1.7 to 2.0 s, and
the sweep read every narinfo it kept. What does a run upload, and what deletes from the bucket?

## Options

Weighed on 2026-10-27; the author chose the third.

- **Keep the sweep and make it cheaper**: one listing in place of three, the narinfos read in
  parallel. The bucket would still be read whole on every run, by every builder, and two
  builders' sweeps could still race, as dpcnp records.
- **Dedup against the bucket**: upload only the paths the bucket lacks. It needs the bucket listed
  or every key asked, the cost measured above, and an object kept for days by being skipped would
  outlive any expiry by age.
- **Upload only what upstream lacks, all of it each run, and let the bucket expire by age**: one
  question to upstream, no reading of the bucket, and nothing to collect.

## Evidence

Nix read at 2.34.9, the version the flake locks, in the repository NixOS/nix; each function below
is named with its directory there, `src/libstore`, `src/libcmd` or `src/nix`, at that tag.

- **Asking upstream costs about a second.** The 720 paths of one builder's closure, asked of the
  public upstream in one parallel `nix path-info --store <upstream> --json`, took 1 s on
  2026-10-27.
- **Nix asks the paths in parallel, and keeps each answer it reads.** `nix path-info` resolves its
  paths with `Realise::Derivation`, the default of `BuiltPathsCommand` in `src/libcmd`, so
  `Installable::build2` in `src/libcmd` prints what is missing through `Store::queryMissing` in
  `src/libstore`, whose `ThreadPool` of `http-connections` asks `Store::isValidPath` of every path
  at once. `Store::queryValidPaths` in `src/libstore` also asks every path on a thread pool, and
  `copyPaths` there uses it to skip what a destination holds, which is why `nix copy` to the bucket
  would skip what exists; `nix path-info` does not call it. After that pool,
  `StorePathsCommand::run` in `src/libcmd` sorts the paths by `Store::topoSortPaths` and
  `pathInfoToJSON` in `src/nix` reads each, both by `Store::queryPathInfo` one path at a time,
  which consults `queryPathInfoFromClientCache`, the memory and then the `NarInfoDiskCache`, first
  and writes each answer back, so a path the builder substituted from upstream while building is
  answered from disk. `Store::isValidPath` writes a positive answer back to neither, its own
  comment says so, so on a cold cache the paths upstream holds are fetched once more in series.
- **A path upstream lacks is `null`, a 403 is `null` too, and anything else fails.**
  `pathInfoToJSON` catches `InvalidPath` alone and writes `null` for it; any other error ends the
  command nonzero, seen on 2026-10-27 against a port that refused the connection.
  `HttpBinaryCacheStore::fileExists` and both forms of `HttpBinaryCacheStore::getFile` in
  `src/libstore` read a 403 as a 404, so a narinfo upstream forbids reads as one it lacks. The run
  asks with `narinfo-cache-meta-ttl` at 0, so `HttpBinaryCacheStore::init` fetches `nix-cache-info`
  every time through `HttpBinaryCacheStore::getNixCacheInfo`, which lets only a 404 through, and
  then asks each path Nix called `null` once more by itself, only a 404 counting as lacking.
- **Upstream's own cache never sweeps as part of an upload.** Its collection in 2026, told in the
  NixOS project's thread on collecting its cache's garbage on its Discourse, read on 2026-10-27,
  was a separate job: the narinfo hashes taken from an S3 Inventory of its bucket, compared with
  Hydra's records, and the resulting datasets removed by Narwal's `gc simple`, with bucket
  versioning on and a lifecycle rule deleting the non-current versions after 30 days as the way
  back.

## Decision

Decided by the author on 2026-10-27, unless marked provisional. It supersedes the sweep of
monoflake/cloud's RFC u9fxz, a run's first step deleting what no pending pointer references, and
every part of that repository's RFC dpcnp that serves the sweep: a builder sweeping only what its
consumers have moved past, asked by `applied`, the deltas and the two hours that spare the young,
and the self marker that keeps a builder's closure. The pointer, the claims and the slots of dpcnp
stand, and so does a builder's taking its own system through the cache.

- **A run publishes only what upstream lacks.** After building the machine's system, its whole
  closure is asked of upstream, `machine.cache.builder.upstream`, the public upstream's binary
  cache by default, which every mirror the fleet uses copies, in one
  `nix path-info --store <upstream> --json`. The paths upstream lacks are the run's own set, and
  only they go to the bucket, signed by the builder's key. Local signatures decide nothing: of one
  builder's 720-path closure, 375 carried no signature of upstream's key, yet upstream held 267
  of them, 298 MiB, and lacked 108, 160 MiB; 368 of the 375 had lost every signature on their way
  from the `/data` chroot store.
- **No dedup.** Every run uploads its whole own set again, even where the keys exist, so each
  object's upload time is fresh for the expiry rule: staged by `nix copy` into a local directory,
  then uploaded by `rclone copy --no-check-dest`, which neither lists nor compares the destination.
  Never `nix copy` to the bucket's S3 store, which skips what exists. NARs go first, then narinfos,
  then the signed pointer last.
- **Nothing deletes but the lifecycle rule.** The sweep goes, and with it everything only it
  served, and every full listing of the bucket but the one measure the cap takes.
- **The cap is on the whole bucket, 5 GB.** Before uploading, a run measures the bucket's total
  once, `rclone size --fast-list`, 3.3 s on one builder on 2026-10-27; at most the cap it uploads,
  and over it it uploads nothing and fails with one line naming the total. Its own set is not added
  to the total, and overshooting by one run or a few concurrent ones, and the lag between an upload
  and the total, are accepted, with no further blocking and no collection. Objects are
  content-addressed, so a re-upload overwrites the same key; the expected peak within the 48 hours
  an object can live is about 1.5 GiB, and even with no dedup at all 28 scheduled runs of 160 MiB
  come to about 4.4 GiB, so no cleanup script is written.
- **A self run publishes nothing**, provisional, chosen by the advisor on 2026-10-27. No fetch and
  no slot reads a builder's own upload: a builder takes its system from another only through the
  ordinary pointer, `pending/<name>/<builder>`, which that builder's run for it writes, and its self
  run takes that first.
- **Expiry is an R2 lifecycle rule**, every object deleted one day after its upload, applied by the
  integrator at rollout. R2 deletes typically within 24 hours of expiry, so an object lives one to
  two days. `nix-cache-info` is uploaded first by every run for another machine once it holds its
  lock, a confirming run included, provisional, chosen by the advisor on 2026-10-27, so it never
  expires while runs go on.
- **Consumers**, provisional, chosen by the advisor on 2026-10-27: the bucket for the deployment's
  own paths, upstream as the machine takes it otherwise for the rest, and every machine with
  `narinfo-cache-positive-ttl = 3600` and `narinfo-cache-negative-ttl = 60`, so an expired path, or
  one uploaded after an earlier miss, is not trusted from a stale local answer for long. A missing
  object fails that fetch, and the machine waits for the next run; a consumer never builds.
- **Accepted consequence**: a machine off for more than a day finds its pointer expired and takes
  its system from the next daily run.

**It carries out monoflake/machine's RFC mgzfp's "the bucket only our own"** on the builder's
side: what upstream lacks is exactly the paths built from a deployment's own sources, its
driver, the machine's modules and its generated configuration, and the bucket holds nothing else.
A consumer takes the rest from the substituters it trusts already, which is where mgzfp's region,
a mirror first in mainland China, will land; until its option does, a machine that carries a mirror
by hand in its deployment's configuration has the fetch take it too.

### Ledger

- **A run that cannot reach upstream fails closed**, provisional, recommended by the integrator on
  2026-10-27: no NAR, no narinfo, no pointer, the old pointer left in place, and the outcome
  `failed` with a line naming upstream. **Each path Nix calls missing is asked again**, provisional,
  chosen by the advisor on 2026-10-27: one `curl` per such narinfo, sixteen at once, a 404 lacking,
  a 200 held, and any other code or a failed `curl` failing the run the same way. Uploading the
  whole closure instead would hide an outage behind a run several times larger.
- **The wrapper keeps `lacks`**, provisional, chosen by the advisor on 2026-10-27: no run asks it
  now, but a builder not yet moved still does of a consumer switched first. `applied`, which only
  the sweep asked, goes. **Follow-up**: `lacks` is removed once every builder runs this design.
- **Every builder moves in one rollout, after its consumers.** A consumer on the old fetch takes
  from the bucket alone, so it must hold the new fetch before any builder stops uploading public
  paths, as mgzfp's "consumers move first" says. A builder on the old code still sweeps, and with no
  builder writing deltas any more it deletes every other builder's objects older than two hours.
