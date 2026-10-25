# The fence

The fence around the driver's containers, `system/network/fence.nix`, built for monoflake/driver's
RFC p95sv and monoflake/platform's RFC y2xd3. The module writes every rule; driver(machine) writes
only the elements of one set.

It covers every driver's bridge alike: the live driver's `driver0`, and `conform0`, where
monoflake/platform's conform runs a second driver on a test machine to prove the platform against
a real one. Both names are constants in `system/network/bridge.nix`, never options, so the scope
check below reads constants alone. While the fence is loaded both bridges take the same rules.

## What the driver writes

The table `inet fence`, the set `reaching`, of type `ipv4_addr . ipv4_addr . inet_service`. Each
element is a container that reaches another deployment, the host's address on its bridge where
the entry listens, and the entry's port:

```sh
nft add element inet fence reaching { 10.88.0.5 . 10.88.0.1 . 36879 }
nft delete element inet fence reaching { 10.88.0.5 . 10.88.0.1 . 36879 }
```

The set is one for both drivers. conform's elements name its own bridge's address and its entry's
port, `46879`, so they are distinct from the live ones, and each driver manages only the elements
whose reacher lies in its own subnet.

The driver writes its elements when it starts and again every 60 seconds, so they come back by
themselves after a boot, which starts the set empty, or after anything else that empties it.
Applying the fence again keeps them: `fence.service` declares the tables and the set where they are
absent and flushes only the chains, and a switch reloads it rather than restarting it. NixOS's own
firewall deletes only its table `inet nixos-fw` when it reloads, never the whole ruleset, as long as
`networking.nftables.flushRuleset` is false, which the module asserts.

## What it lets through

| From a container to            | Passes                                                         |
| ------------------------------ | -------------------------------------------------------------- |
| another container, bridged     | ARP alone; every IPv4 and IPv6 frame is dropped                |
| the host, any of its addresses | a reply to the host, and TCP matching an element of `reaching` |
| a private network, routed      | nothing: RFC 1918, 169.254/16, 100.64/10, ULA, link local      |
| the tailnet, routed            | nothing, by interface as well as by address                    |
| a public address, routed       | as before, the bridge plugin's masquerade unchanged            |

To a container, nothing is forwarded but a reply to a connection the container made, so no
neighbor reaches a container's port by routing through the host. No container publishes a host
port; one that did would be named here, never excepted.

A drop in any base chain is final and an accept is not, so the fence's chains run beside NixOS's
own firewall and the bridge plugin's masquerade and only narrow them. NixOS's firewall opens the
live entry's port on `driver0` alone, and the fence narrows it to the elements. The masquerade is
in the postrouting hook, which a packet to the host itself never passes, so the entry sees a
container's own address.

## conform

`machine.conform` holds conform's entry's port and its driver's port in one place, `46879` and
`47483` by default, the values monoflake/platform's conform uses; its bridge is the constant
`conform0`. It is off unless a machine sets `machine.conform.enable`, as a test machine conform
runs on does, and then opens conform's entry on `conform0` alone in NixOS's firewall and keeps both
ports out of the ephemeral range beside the live ones. A machine that never runs conform opens
nothing for it, and its bridge is in the fence's rules all the same, so where conform runs there
anyway, its entry is closed and its containers are held by the fence while the fence is loaded.

What the machine does not hold is the order. The live driver and its entry require the fence, but
conform's driver is a transient unit conform starts itself, which the module's drop-in makes
require /data and nothing of the fence, so were the fence absent, as before it loads at boot,
conform would still start and its containers would run unfenced. Refusing to start without the
fence's tables is conform's to do.

## What holds it

The fence is not tried and not rolled back, RFC p95sv. Two things hold it instead.

- **A check at build.** The ruleset's own check fails the build unless every rule in a base chain
  matches by `driver0` or `conform0` or their ports, by `iifname`, `oifname`, `meta ibrname` or
  `meta obrname`; every other chain is reached only by such a rule and jumps nowhere; every base
  chain is a filter whose policy is accept; and no table but the two fences is written. So the
  fence cannot touch the machine's other traffic, its remote access included. `nft --check` then
  loads it into a kernel of its own, as NixOS checks its own ruleset.
- **Fail closed.** `driver-machine` and `driver-machine-entry` require the fence and start after
  it, so neither runs without it, and stopping the fence stops both.
