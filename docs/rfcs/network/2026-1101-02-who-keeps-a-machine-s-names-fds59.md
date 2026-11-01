---
name: "Who Keeps a Machine's Names"
title: 'Who reads the addresses a machine learns, and holds the credential that changes its names'
status: draft
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

A machine can learn its own public addresses, RFC co32d, and the author decided on 2026-10-26 that
**a name for each machine follows them, and no DNS credential is kept on any machine**; the DNS
provider's API is chosen later. Who reads the addresses and holds the credential that changes the
names is open, and nothing past a machine learning its addresses is built until the author chooses.
Moved here from RFC co32d on 2026-11-01, when the rest of it landed.

## Options

Raised by the author and the advisor on 2026-10-26, for the second half of the question.

- **(i) The machine tells the control**: each machine sends a confirmed change over HTTPS to the
  control, with a token of its own that can change its own record alone, and the control holds the
  DNS credential. No machine holds that credential, and a machine taken over can lie only about
  itself. It turns the author's "the control asks" into "the machine tells".
- **(ii) One machine asks the rest**: a job on one machine of the tailnet asks every machine by
  name and changes the names. It holds the DNS credential on that one machine, which the author
  ruled out.
- **(iii) The control asks each machine's driver**: every machine runs the machine driver and is
  bound, and the control asks through each binding's reach, monoflake/platform's RFC 8j7b0. It is a
  change at the platform's level, and every machine is bound.

## Evidence

- The author's shape, the control asking each machine's driver over the tailnet, does not match the
  code as it stands on 2026-10-26: the control is a Cloudflare Worker, off the tailnet, and reaches
  a driver only through its binding's reach, a public origin or a tunnel; and only the two machines
  that host bindings run the machine driver.
- **Read over the tailnet, if it fits**, provisional, chosen by the advisor on 2026-10-26: through
  the read-only wrapper of the user `machine-cache` where that widens nothing it allows, and left
  out otherwise until the question above is answered.
- **The proxy's own throwaway zone is the one exception to no DNS credential on a machine**,
  decided by the author on 2026-10-26: every node running egress holds a token scoped to that one
  zone, which serves nothing else, and changes its own name in it. Where those addresses come from
  is an open question of egress's design. Every other zone keeps the rule.
