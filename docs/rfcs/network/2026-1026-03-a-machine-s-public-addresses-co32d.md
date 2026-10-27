---
name: "A Machine's Public Addresses"
title: 'How a machine learns its own public addresses, and who reads them to keep its names pointing at it'
status: draft
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

A machine's public address can change, rarely, as a cloud machine's does after a stop and a start.
Decided by the author on 2026-10-26: **every machine learns its own public IPv4 and IPv6 addresses
about hourly, from two sources that must agree, Tailscale's netcheck and Cloudflare's trace, a name
for each machine follows them, and no DNS credential is kept on any machine**; the DNS provider's
API is chosen later. Who reads the addresses and holds the credential that changes the names is
open, and nothing past a machine learning its addresses is built until the author chooses.

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
- Tailscale's `netcheck` reports the address its STUN servers saw, and Cloudflare's
  `/cdn-cgi/trace` the address a request reached Cloudflare's anycast resolver from, each family
  asked apart, so two sources run by two vendors can be compared.
- A machine without an address of a family, as one with no public IPv6, has nothing to report for
  it, which is no failure.

### Ledger

Choices made provisionally while the thread runs, read by the author at its end.

- **A unit of the machine's own**, provisional, chosen by the advisor on 2026-10-26:
  `machine.addresses.enable`, off by default, checks at boot and every hour, each family apart. An
  address is taken only where both sources agree, and a change from the last one confirmed only
  when a second check a minute later agrees again.
- **Each family's state**, provisional, chosen by the advisor on 2026-10-26: `confirmed` with its
  address, `disputed` when the sources disagree, `unknown` when one cannot be reached, each keeping
  the last confirmed address with the reason, and `none` for a family the machine lacks; written to
  `/var/lib/machine/addresses.json`, so a restart keeps the last confirmed address.
- **Read over the tailnet, if it fits**, provisional, chosen by the advisor on 2026-10-26: through
  the read-only wrapper of the user `machine-cache` where that widens nothing it allows, and left
  out otherwise until the question above is answered.
- **The proxy's own throwaway zone is the one exception to no DNS credential on a machine**,
  decided by the author on 2026-10-26: every node running egress holds a token scoped to that one
  zone, which serves nothing else, and changes its own name in it. Where those addresses come from
  is an open question of egress's design. Every other zone keeps the rule.
