# The tailnet

Every machine runs unstable's Tailscale and keeps the tailnet's resolver out of its nameservers,
`system/network/tailnet.nix`. It joins the tailnet at boot with `machine.tailnet.authKeyFile` where
one is set, or is logged in by hand. Its interface is not trusted by the host firewall,
[network.md](network.md#public-ssh).

## The host firewall

**Peerapi needs no host firewall opening with the locked Tailscale 1.104.2.** No fixed port or
dynamic port range is opened for it. See upstream's
[port advertisement](https://github.com/tailscale/tailscale/blob/v1.104.2/ipn/ipnlocal/local.go)
and [listener](https://github.com/tailscale/tailscale/blob/v1.104.2/ipn/ipnlocal/peerapi.go#L93-L158).

- **Remote peerapi TCP terminates in tailscaled's netstack before it reaches the TUN device.**
  Thus the host firewall sees no remote peerapi connection to drop,
  [`netstack.go`](https://github.com/tailscale/tailscale/blob/v1.104.2/wgengine/netstack/netstack.go#L1253-L1276)
  and [`injectInbound`](https://github.com/tailscale/tailscale/blob/v1.104.2/wgengine/netstack/netstack.go#L1440-L1488).
  The Linux kernel listener is for local use,
  [`peerapi_linux.go`](https://github.com/tailscale/tailscale/blob/v1.104.2/ipn/ipnlocal/peerapi_linux.go).
  A build without netstack would need a different firewall decision; no port range is opened in
  anticipation of one.
- **An app connector's split DNS follows the same peerapi path**, so removing interface trust
  requires no DNS opening. Tailscale's peer permissions still apply,
  [the handler](https://github.com/tailscale/tailscale/blob/v1.104.2/ipn/ipnlocal/peerapi.go#L802-L909)
  and [the client forwarder](https://github.com/tailscale/tailscale/blob/v1.104.2/net/dns/resolver/forwarder.go#L692-L699).
- **The peer relay's public UDP opening stays as declared by `machine.tailnet.relayPort`**, and
  `services.tailscale.openFirewall` still opens Tailscale's own UDP transport port,
  `system/network/tailnet.nix`. Neither depends on trusting the tailnet interface. The relay's
  input path is described below.
- **DERP connections are outbound TCP on HTTPS, unchanged by the input policy**,
  [Tailscale's firewall requirements](https://tailscale.com/kb/1082/firewall-ports).
  **MagicDNS at `100.100.100.100` is served inside tailscaled**, not by a host input listener,
  [the local resolver](https://tailscale.com/kb/1381/what-is-quad100). The machine still declines
  the tailnet's DNS configuration; a client's MagicDNS behavior does not change.
- **Ordinary ping over the tailnet remains allowed by NixOS's firewall.** `allowPing` defaults to
  true for ICMPv4 echo requests, and its nftables backend permits ICMPv6 echo requests regardless
  of that option,
  [`firewall.nix`](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/nixos/modules/services/networking/firewall.nix#L175-L184)
  and [`firewall-nftables.nix`](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/nixos/modules/services/networking/firewall-nftables.nix#L170-L176).
  Tailscale's access policy still applies. No ICMP exception is needed here.

**Tailscale's `ts-input` and `ts-forward` accepts cannot override a NixOS drop.** NixOS's
`inet nixos-fw` input base chain has policy drop and accepts only what its own rules allow,
[`firewall-nftables.nix`](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/nixos/modules/services/networking/firewall-nftables.nix#L101-L138).
An accept in one base chain still passes through the other base chains at that hook, whereas a
drop is final, [nftables' chain semantics](https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains#Base_chain_policy).
Peerapi stays reachable because it terminates before host input, not because `ts-input` rescues it.

**Exit-node forwarding does not change.** Interface trust is an input rule, not a forwarding
rule. NixOS's `filterForward` remains at its default false,
[`firewall.nix`](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/nixos/modules/services/networking/firewall.nix#L235-L243).
The exit node's forwarding sysctls, Tailscale's forwarding rules and the containers' fence stay as
they are. DNS through an exit node uses the same peerapi path above.

## An exit node

**A machine may advertise itself as a Tailscale exit node, and none does by default**, decided on
2026-10-26 at the author's request, its details provisional and chosen by the advisor: this
repository is a public product and an exit node is no default, so `machine.tailnet.exitNode` is
off, and a deployment that wants one sets it on.

On, it sets `services.tailscale.useRoutingFeatures = "server"`, which turns on
`net.ipv4.conf.all.forwarding` and `net.ipv6.conf.all.forwarding`, and adds
`--advertise-exit-node` and `--stateful-filtering=true` to the flags `tailscaled-set` passes to
`tailscale set` at every boot and switch, a switch starting it again with `multi-user.target`.
They go there and not to `extraUpFlags`, which NixOS passes only to the `tailscale up` run while
the machine needs a login, `tailscale.nix:216-218` at the locked nixpkgs, and never to a machine
already up.

- **An advertised exit node carries nothing until the tailnet's admin approves it**, in the admin
  console or by an `autoApprovers` entry in the tailnet's policy,
  https://tailscale.com/kb/1103/exit-nodes.
- **Stateful filtering is Tailscale's own guard for a forwarding node**: it drops a packet
  forwarded onto the tailnet's interface that opens a connection, so nothing beside the machine
  reaches the tailnet through it, `AddStatefulRule` in Tailscale 1.104.2's `util/linuxfw`,
  `iptables_runner.go` and `nftables_runner.go`. The other way, while the fence is loaded, a
  tailnet's device reaches no container through the exit node either, as nothing is forwarded to a
  driver's bridge but a reply, [fence.md](fence.md).
- **Turning it off does not withdraw it.** `tailscale set` changes only the flags it is given, so a
  machine that dropped the option goes on advertising, with `--stateful-filtering` still on. Its
  forwarding stays on until the next boot and is off after it, while the node still advertises, so
  a client using it as its exit node loses its traffic. Run
  `tailscale set --advertise-exit-node=false` on the machine by hand when the option is dropped.

## A peer relay

**A machine may serve as a Tailscale peer relay, and none does by default**, decided on 2026-10-26
at the author's request, its details provisional and chosen by the advisor: this repository is a
public product and a relay is no default, so `machine.tailnet.relayPort` is null, and a deployment
that wants one sets the fixed UDP port it serves on, as `40000`. The option refuses `0`, which
Tailscale reads as a random port that no firewall line could name.

A peer relay carries WireGuard's ciphertext between two of the tailnet's nodes that cannot connect
directly, and cannot read what it carries, https://tailscale.com/kb/1591/peer-relays. Set, the
option adds `--relay-server-port=<port>` to the flags `tailscaled-set` passes to `tailscale set` at
every boot and switch, as the exit node's are, opens the port in NixOS's firewall and adds it to
`machine.reservedPorts`.

- **Tailscale opens no firewall port for it.** The one port it opens is its own, by a rule in its
  own chain `ts-input`, `wgengine/router/osrouter/router_linux.go` in Tailscale 1.104.2, and an
  accept there cannot override the drop of NixOS's own `nixos-fw` input chain. So the option adds
  the relay's port to `networking.firewall.allowedUDPPorts`, accepted on input where `openFirewall`
  accepts Tailscale's own. The relay's packets enter and leave on the machine's own interface and
  none is forwarded, so the fence and the driver's ports are not touched, [fence.md](fence.md).
- **The port is kept from the range Linux gives a connection its own port from**, joining the
  entry's, the driver's and conform's in `net.ipv4.ip_local_reserved_ports`, so no outgoing
  connection takes it before the relay binds it, `system/network/default.nix`.
- **The port has to be reachable from where the clients are**, so a provider's firewall in front
  of the machine opens it too.
- **A relay carries nothing until the tailnet's policy grants it**: a grant whose `dst` is the
  relay and whose app capability is `tailscale.com/cap/relay`.
- **It sits beside the exit node with no conflict.** Stateful filtering matches only traffic
  forwarded out of `tailscale0`, and a relay's packets are the machine's own.
- **A `tailscale up` that is not an edit resets it.** One run with an auth key, a reauth, changed
  tags or a changed login server, or one given any flag while the node is not running, starts the
  node with every pref it is not given reset, the relay's port among them, as `updatePrefs` in
  Tailscale 1.104.2's `cmd/tailscale/cli/up.go` takes an edit only otherwise. The next boot or
  switch sets the port again.
- **Removing it does not withdraw it.** `tailscale set` changes only the flags it is given, so a
  machine that dropped the option goes on announcing itself as a relay with its port now closed;
  a client's attempt through it fails, and the client falls back to another path. Run
  `tailscale set --relay-server-port=""` on the machine by hand when the option is dropped, which
  clears it.

On the relay, `tailscale debug peer-relay-sessions` lists the sessions it carries; from a client,
`tailscale ping <peer>` shows `via peer-relay(...)` when a relay carries the path.

## Routes

**A machine advertises the subnet routes its configuration lists, `machine.tailnet.routes`, and no
others**, provisional, chosen by the advisor on 2026-10-26 at the author's request that a server
advertise its own LAN address as a /32 and never a whole subnet. The list is passed as
`--advertise-routes` at every boot and switch, an empty one included: Tailscale 1.104.2's
`tailscale set` keeps an exit node's two default routes beside it and drops a route set by hand, so
the configuration is the only source. A route carries nothing until the tailnet approves it.

- **A machine never accepts routes**: an assertion refuses `--accept-routes` in its flags but as
  `--accept-routes=false`, so a server's own subnet stays its own however others advertise it.

## Tags

**A server joins the tailnet as `tag:server`, and a peer relay as `tag:relay` beside it; a person's
devices stay owned by their user**, decided by the author on 2026-10-26. A machine takes its tags
from the single-use auth key it logs in with, or through the tailnet's API, and leaves
`autogroup:self` with them. The tailnet's policy approves a tagged server's exit node by
`autoApprovers` and grants the relay by its tag, so neither waits on a hand.

**A region tag names where traffic leaves**, decided by the author on 2026-10-27 for any region
tag the tailnet takes: lowercase English, a large country written as country and region joined by
one hyphen, as `tag:us-west`, and a small place written whole with no hyphen, as `tag:hongkong`,
`tag:taiwan` or `tag:singapore`. Tags live only in the tailnet's policy and on its devices, so no
check in this repository can read them, and the rule is kept by judgment.
