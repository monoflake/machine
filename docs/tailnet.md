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
