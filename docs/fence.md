# The fence

The fence around the driver's containers, `system/network/fence.nix`, built for monoflake/driver's
RFC p95sv and monoflake/platform's RFC y2xd3. The module writes every rule; driver(machine) writes
only the elements of one set.

## What the driver writes

The table `inet fence`, the set `reaching`, of type `ipv4_addr . ipv4_addr . inet_service`. Each
element is a container that reaches another deployment, the host's address on `driver0` where the
entry listens, and the entry's port:

```sh
nft add element inet fence reaching { 10.88.0.5 . 10.88.0.1 . 36879 }
nft delete element inet fence reaching { 10.88.0.5 . 10.88.0.1 . 36879 }
```

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
entry's port on `driver0` alone, and the fence narrows it to the elements. The masquerade is in the
postrouting hook, which a packet to the host itself never passes, so the entry sees a container's
own address.

## What holds it

The fence is not tried and not rolled back, RFC p95sv. Two things hold it instead.

- **A check at build.** The ruleset's own check fails the build unless every rule in a base chain
  matches by `driver0` or its ports, by `iifname`, `oifname`, `meta ibrname` or `meta obrname`;
  every other chain is reached only by such a rule and jumps nowhere; every base chain is a filter
  whose policy is accept; and no table but the two fences is written. So the fence cannot touch
  the machine's other traffic, its remote access included. `nft --check` then loads it into a
  kernel of its own, as NixOS checks its own ruleset.
- **Fail closed.** `driver-machine` and `driver-machine-entry` require the fence and start after
  it, so neither runs without it, and stopping the fence stops both.
