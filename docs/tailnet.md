# The tailnet

Every machine runs unstable's Tailscale, trusts its interface in NixOS's firewall and keeps the
tailnet's resolver out of its nameservers, `system/network/tailnet.nix`. It joins the tailnet at
boot with `machine.tailnet.authKeyFile` where one is set, or is logged in by hand.

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
