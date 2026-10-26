---
name: 'Public Paths From Upstream'
title: 'Public paths from upstream or a mirror near the machine, the bucket only our own'
status: accepted
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

A builder today uploads to the deployment's bucket every path of a machine's closure the machine
lacks, nixpkgs' paths among them, and a builder above 4096 MB uploads what the bucket lacks of its
own closure. Most of those paths are already served by the NixOS cache, the NixOS project's
public binary cache, signed by its key, and a machine on the mainland of China reaches neither the
NixOS cache nor a builder in the United States quickly, where a mainland mirror of the NixOS
cache's store answers fast. Where should a machine take each path from, and what is the bucket
left to carry?

## Decision

**A machine substitutes public paths from the best upstream for its region, and the bucket carries
only what upstream lacks**, decided by the author on 2026-10-26: the NixOS cache for a machine
anywhere it serves well, a mainland mirror of the NixOS cache's store for a machine in mainland
China, and the bucket for the paths built from a deployment's own sources, its driver, the
machine's modules and its generated configuration.

### Ledger

- **A region picks the substituters**, provisional, chosen by the advisor on 2026-10-26: a
  machine option with the values `global`, the default, and `china`. Whether it becomes one region
  field from which `machine.network.resolvers` is derived as well is open, and resolvers is not
  changed with it.
- **The order and the keys**, provisional, chosen by the advisor on 2026-10-26: `china` takes the
  mirror first, then the NixOS cache, then the bucket; `global` takes the NixOS cache, then the
  bucket. The trusted keys are the NixOS cache's own key and the machine's builders' keys, with
  `require-sigs` on, so a mirror is transport alone and signs nothing. A path no source holds fails
  the fetch and is seen, as it is today.
- **A builder's delta is what upstream lacks**, provisional, chosen by the advisor on 2026-10-26:
  a path counts toward the upload only where the NixOS cache has no narinfo for it, the builders
  being where that query is fast. What is uploaded still goes in two passes, every object before
  its narinfo, as the self marker's change requires.
- **Consumers move first**, provisional, chosen by the advisor on 2026-10-26: every machine trusts
  the NixOS cache and holds the new substituter list before any builder stops uploading public
  paths, the principle of the pointer layout's rollout, held by a check beside the one that keeps
  a builder's and its consumers' locks on one layout, or by extending it.
- **When**, provisional, chosen by the advisor on 2026-10-26: built in a lane after the pointer
  layout's rollout, landing with the self marker or after it. A machine installed before it lands
  may carry its substituters by hand in its deployment's configuration, citing this RFC, and drops
  them when the option lands.
- **What it does to a self upload**: a builder above 4096 MB uploads only the paths of its own
  closure that the NixOS cache lacks, its system's own derivations and what a deployment builds,
  in place of every path the bucket lacks; a first day's self upload shrinks from the whole
  closure's missing part to that remainder, and so does what the self marker keeps against the
  cap. The sizes are measured when it lands.
