---
name: "A Machine's Public Addresses"
title: 'How a machine learns its own public addresses, and who reads them to keep its names pointing at it'
status: landed
supersedes: []
blocked-by: []
commits:
  - monoflake/machine@715afb14
  - monoflake/cloud@3074c859
references: []
---

## Question

A machine's public address can change, rarely, as a cloud machine's does after a stop and a start.
Decided by the author on 2026-10-26: every machine learns its own public IPv4 and IPv6 addresses
about hourly, from two sources that must agree, Tailscale's netcheck and Cloudflare's trace. Who
reads them and changes a name moved to RFC fds59. Decided by the author on 2026-11-01: each machine
also declares which public families it has, IPv4 and IPv6 each supported or not, whether it sits
behind NAT, and where it does, whether its router forwards the ports it uses. A forwarded port counts
as a public one, since the author opens a forward for whatever a machine needs.

## Evidence

- Tailscale's `netcheck` reports the address its STUN servers saw, and Cloudflare's
  `/cdn-cgi/trace` the address a request reached Cloudflare's anycast resolver from, each family
  asked apart, so two sources run by two vendors can be compared.
- A machine without an address of a family, as one with no public IPv6, has nothing to report for
  it, which is no failure.
- On 2026-11-01 the advisor probed the relay port of iris and lime, Azure machines whose only
  public address is IPv6, at an IPv4 they do not hold, their default outbound one, and read the
  silence as a closed port. A declaration of their families would have named the probe to run.

- A read-only survey on 2026-11-01 of fourteen machines, each's interface and each family's trace,
  agreed with the values declared; pine, ivy and dusk were not read.

## Decision

1. **`machine.addresses.enable`, off by default**, a unit of the machine's own checking at boot and
   every hour, each family apart, provisional, chosen by the advisor on 2026-10-26. An address is
   taken only where both sources agree, and a change from the last one confirmed only when a second
   check a minute later agrees again. Each family is `confirmed` with its address, `disputed` when
   the sources disagree, `unknown` when one cannot be reached, each keeping the last confirmed
   address with the reason, or `none`, written to `/var/lib/machine/addresses.json`. It stays off:
   nothing reads it.
2. **`machine.network.public = { ipv4; ipv6; }`, each `direct`, `mapped`, `forwarded` or `none`, with
   no default**, proposed by the advisor and accepted by the author on 2026-11-01, so every fleet
   machine states it and the base layer a runner takes does not. `none` covers outbound only. A peer
   relay is not derived from it: a relay needs only its port reachable, by a public address or a
   forward, and `machine.tailnet.relayPort` stays its own option.
3. **monoflake/cloud's `mise run pointer` compares what a machine sees with it**, a warning naming no
   address and never a failure, as `machine.memory`'s difference is, and tests only declared
   families. It reads the interfaces and Cloudflare's trace over SSH, needing no `machine.addresses`.
   It tests outbound alone; no inbound probe exists.
4. ivy and dusk, frozen and unbound, declare `forwarded` for both families, the author's word of
   2026-11-01; they take no pointer, so nothing compares them until they return.
