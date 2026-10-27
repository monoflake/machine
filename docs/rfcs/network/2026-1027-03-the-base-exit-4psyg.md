---
name: 'The Base Exit'
title: 'Nodes inside a censored border reach GitHub through a Tailscale App Connector outside it, so base traffic never waits on a platform service'
status: draft
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

A node inside a censored border reaches GitHub badly or not at all, and its base work, the control
plane and the infrastructure it runs on, needs GitHub's releases and sources. monoflake/egress's
RFC fcno9 routes business traffic between the nodes, yet egress reaches a node through its driver,
which is bound first, so egress cannot carry what binding needs. Decided by the author on
2026-10-27, **base traffic never depends on a service the platform deploys, and business traffic
depends on base, never the reverse**, which breaks that loop:

- **Base leaves through a Tailscale App Connector.** The connector is one node outside the border,
  tagged `tag:hongkong` by the region-tag rule of [tailnet.md](../../tailnet.md#tags). Its clients
  are the nodes inside the border, tagged `tag:mainland`, the author's name for a tag of another
  kind, one that names where a node sits rather than where its traffic leaves.
- **The connector carries GitHub alone**, four domains: GitHub's own and its user content's, each
  as itself and as a wildcard below it. Cloudflare's API answers well from inside the border and
  goes direct.
- **The tailnet's policy holds the rest, live, and never in a repository**: a `nodeAttrs` entry
  whose target is `tag:mainland`, naming the app `base` with `tag:hongkong` as its connectors and
  the four domains; a grant from `tag:mainland` to `tag:hongkong` on `tcp:53` and `udp:53`, and one
  from `tag:mainland` to `autogroup:internet` on `tcp:443` and `tcp:22`; and an `autoApprovers`
  entry approving both default routes, IPv4's and IPv6's, for `tag:hongkong`, so a learned route
  waits on no hand.
- **This repository gains two options.** A connector option that adds `--advertise-connector` to
  the flags `tailscaled-set` passes at every boot and switch, as the exit node's are, with
  `tailscaled-set` changed so that it never overwrites the routes a connector learned. And an
  option for a client inside the border that adds `--accept-dns=true` and `--accept-routes`.

Landing it narrows three rules of [tailnet.md](../../tailnet.md): that the tailnet carries no
traffic steering and holds no App Connector, which stays true of business traffic, the base
connector being the one exception; that a machine keeps the tailnet's resolver out of its
nameservers; and that a machine never accepts routes, both of which a client inside the border
takes by its option.

**The control answers on the control's custom domain, a name of its own on Cloudflare, and needs
nothing from the base connector**, decided by the author on 2026-10-27. Its address on Cloudflare's
own Workers domain did not answer from inside the border, and that address is turned off. The
custom domain is reached from inside: in that day's test IPv6 was steady and IPv4 flaky.

## Evidence

- **An app connector keeps the routes it learns in the same pref `--advertise-routes` sets.**
  `AdvertiseRoute` in Tailscale 1.104.2's `ipn/ipnlocal/local.go:8571` appends each learned prefix
  to `AdvertiseRoutes` by an edit of the prefs, and a `tailscale set` that names
  `--advertise-routes` clears the connector's routes first, `MaybeClearAppConnector` called from
  `ipn/localapi/localapi.go:1010`. Today `tailscaled-set` passes the configured list at every boot
  and switch, an empty one included, [tailnet.md](../../tailnet.md#routes), so each would drop
  what the connector learned. Read on 2026-10-27.

### Ledger

Choices made provisionally while the thread runs, read by the author at its end.

- **`tailscaled-set` passes a route flag only where it is set**, provisional, chosen by the advisor
  on 2026-10-27, so that a switch never clears the connector's routes: `--advertise-routes` only
  where routes are configured and `--advertise-exit-node` only on an exit node, neither else.
- **The connector runs with stateful filtering on, as an exit node does**, provisional, chosen by
  the advisor on 2026-10-27 after the integrator's proposal, so that a connection from outside
  cannot enter the tailnet through it. `--stateful-filtering` sets `NoStatefulFiltering` alone,
  Tailscale 1.104.2's `cmd/tailscale/cli/up.go:921`, so it never clears the connector's routes.
- **A machine is no connector by default**, provisional, chosen by the advisor on 2026-10-27, this
  repository being a public product.

### Owed before it is trusted

- **The author's laptop must not install the connector's learned routes.** It is tagged
  `tag:owner`, granted `tag:server:*` and `autogroup:internet`. The `nodeAttrs` target scopes which
  nodes are handed the connector's DNS configuration, but it may not scope which nodes the learned
  routes reach, which are subnet routes like any other and could go to every node that accepts
  routes and is granted their destination. A test on the live tailnet answers it; if the laptop
  takes them, its GitHub traffic leaves through the connector, and the design needs an answer on
  the laptop's side before it lands.
