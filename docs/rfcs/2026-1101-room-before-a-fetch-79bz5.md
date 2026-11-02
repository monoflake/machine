---
name: 'Room Before a Fetch'
title: "A machine's system profile keeps a generation only while it is among the newest three and younger than three days, the booted and the current one always, as a store on a 5 GB root holds about two closures"
status: landed
supersedes: []
blocked-by: []
commits:
  - monoflake/machine@04b3a0da
  - monoflake/cloud@54d3f914
  - monoflake/cloud@cbaf60a9
  - monoflake/cloud@4953f7b1
references: []
---

## Question

A machine's root partition is 5 GB, `/` and `/nix/store` together, `machine.disk`'s layout, and
holds the booted closure plus at most about one more. A whole new system brings 1.3 to 1.5 GiB, as
B's switches did on 2026-11-01; two days of nixpkgs brought 204 MiB to fog an hour later. B's
machines had 267 MiB to 1.3 GiB free then, snow and lime under 400 MiB, each holding two dead
generations, frozen systems from 2026-10-28 and 10-29, which `system/nix/collect.nix`'s rule of the
last three systems kept. Deleting them freed 1.3 GiB on fog, rebooted since its switch, and 44 to
357 MiB on the six not rebooted, whose booted system, the old one, stays a root while it runs. The
pressure came mostly from the long freeze, the author's reading, so it is not urgent.

Which system generations does a machine keep?

## Decision

1. **A generation is kept only while it is among the newest three and younger than three days**,
   and goes past either limit; the booted generation and the current one are always kept. Decided
   by the author on 2026-11-01, replacing the last three systems kept in `system/nix/collect.nix`.
   `boot.loader`'s `configurationLimit` of 3 stays as it is.
2. `system/nix/collect.nix` deletes the system profile's generations by count, then by age, before
   it collects, with a guard keeping the booted system's generation, and an eval test holding it.
3. It is the next monoflake/machine change after the tailnet change of 2026-11-01 reaches A, and
   pine's ring build, and rolls through C, B and A under the canary rule, monoflake/cloud's
   `docs/upgrades.md`.
