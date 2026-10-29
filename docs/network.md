# The network

A machine takes its addresses by DHCP and keeps fixed nameservers, `system/network/default.nix`,
unless its provider gives no DHCP.

## A machine its provider gives static addresses

**A machine whose provider offers no DHCP and no router advertisement reads its addresses from the
provider's cloud-init NoCloud seed at every boot, never from a repository**, decided by the author
on 2026-10-26: its addresses are the provider's to know, and a deployment's repository holds none
of them, not even encrypted. `machine.network.seed` turns it on, and no machine has it by default.

On, the machine runs systemd-networkd in place of dhcpcd, and before networkd starts
`machine-seed-network.service` mounts the seed, the iso9660 disk labeled `cidata`, read-only,
renders its `network-config` into `/run/systemd/network/10-seed.network` matched by the ethernet's
MAC address, and unmounts it, `system/network/seed/`. The seed's nameservers are passed over, as
the module's fixed ones stand.

- **The seed read is netplan's version 2 with one ethernet**: its MAC address, its addresses with
  their prefix lengths, a gateway for each family inside its own prefix, and DHCP off. Any other
  shape is refused by name, since a general cloud-init is not what this reads.
- **A seed missing, unreadable or refused falls back to the last one read and fails the unit**,
  provisional, chosen by the advisor on 2026-10-26: each read that succeeds keeps its rendering in
  `/var/lib/machine/seed-network`, so a provider that drops or changes the seed costs an alarm and
  not the machine. With neither, the machine has no network and only the provider's console
  reaches it.
- **Nothing in the unit needs the network**, and it never leaves a partial file where networkd
  reads, writing beside it and renaming.

## Its resolvers

**A machine's nameservers are a region's preset, `machine.network.resolvers`**, provisional, chosen
by the advisor on 2026-10-26: `global`, the default, is 1.1.1.1 and 8.8.8.8, and `china` is
AliDNS's 223.5.5.5 and 223.6.6.6, for a machine where the global ones are blocked.
`/etc/resolv.conf` stays a plain file listing them, which every container binds as it is.

## Its TCP

**Every machine runs BBR over fq, and caps every socket buffer at `machine.network.buffer`, 32 MiB
by default**, decided by the author on 2026-10-29, `system/network/tcp.nix`: the cap is the largest
`net.core.rmem_max` and `wmem_max`, and the most `net.ipv4.tcp_rmem` and `tcp_wmem` grow to from
4 KiB and their 128 KiB and 16 KiB defaults. A machine of several Gbit/s on long paths raises it
in its own configuration, to 128 MiB. Measured by the advisor the same day with iperf3 over public
IPv4 on 443, ten seconds a run:

- **Cubic over fq_codel with a 4 MiB cap left the long paths far below their ports**: one flow at
  68, 100 and 167 ms between machines of 4 Gbit/s ran 372, 256 and 151 Mbit/s, one from a machine
  of 200 Mbit/s at 151 ms ran 55, and one to a 1 Gbit/s port policed near 700 ran 173.
- **BBR over fq with a 128 MiB cap filled them**: the same three paths of 4 Gbit/s ran 2.9 to 3.3
  Gbit/s on one flow and 3.8 to 4.0 on four, the port's cap, retransmitting 1 to 3 percent, the
  processor at most 22 percent of four cores.
- **A provider's policer is not something TCP tuning removes**: the machine of 200 Mbit/s, with
  BBR and 32 MiB, ran 164 to 195 Mbit/s with 14,000 to 30,000 retransmits in ten seconds against a
  policer near 200, and the 1 Gbit/s port policed near 700 went from 173 to 670 Mbit/s. Shaping a
  machine's egress below its policer is RFC la4oy, a draft.

`net.core.default_qdisc` applies only to a qdisc created after it is set, so a switch leaves an
interface already up on the qdisc it had; after the switch that brings this in, the NIC's root is
checked to be `fq`, or `mq` with `fq` beneath it, and not `fq_codel`. Whether a container's network
namespace, which the driver creates, inherits `bbr` is confirmed on the test platform, and if it
does not, the driver sets it.

## Public SSH

**The tailnet interface is not trusted by the host firewall, and its only allowed TCP port is
SSH**, decided by the author on 2026-10-26, `system/network/default.nix`. The interface is read
from `services.tailscale.interfaceName`. The driver's port is opened on no interface, and neither
it nor the entry's port is opened on the tailnet. The control reaches both through the Cloudflare
tunnel to the machine itself, `system/network/tunnel.nix`, and the author through SSH then
`localhost`. The entry's opening on the containers' bridge stays fenced, [fence.md](fence.md).
Tailscale's own traffic is accounted for in [tailnet.md](tailnet.md#the-host-firewall).

**Public port 22 is open by default, and the machine closes it itself once it works**, decided by
the author on 2026-10-26; the seconds it is open around a boot or a switch are accepted. Every
machine sets `services.openssh.openFirewall`, so the base firewall always accepts 22, and SSH takes
the machine's keys alone, never a password. **A machine authorizes the author's key alone, written
without its comment**, decided by the author the same day; a machine's builders reach the user
`machine-cache` by their own restricted keys, `nix/cache/fetch.nix`.

`machine.ssh.public`, `until-healthy` by default, runs `machine-ssh-close` each minute,
`system/network/ssh.nix`: while Tailscale reports itself running and online, it adds a table of its
own ahead of NixOS's filter that drops 22 arriving on any interface but the configured tailnet
interface and `lo`.
**Port 22 over the tailnet and over loopback is never dropped by it, in any state**, as it is the
author's way in. A firewall reload removes the table, and nftables' start and reload run the
closer again at once. `open` leaves 22 open always, for a machine under repair.

- **Public 22 opens again when the tailnet is lost**, provisional, chosen by the advisor on
  2026-10-26: while its table is in place, five unhealthy checks in a row, whatever the state the
  tailnet reports and a logout among them, delete the table and fail the unit naming the state it
  saw, so a dead tailnet leaves a machine reachable by its key instead of needing a visit. Fewer
  leave 22 closed, so a tailnet restarting with a switch opens nothing.
- **Without its table, 22 is open and only the alarm waits**, provisional, chosen by the advisor
  the same day: a machine never logged in counts nothing, and any other unhealthy state counts only
  ten minutes after boot, so a tailnet that does not come back after a reboot raises the alarm at
  about fifteen minutes. A reload that flushed the table counts nothing either; the next healthy
  check puts it back.

## Its public addresses

**A machine can learn its own public addresses, `machine.addresses.enable`, off by default**, the
half of RFC co32d that is decided: at boot and every hour it asks Tailscale's netcheck and
Cloudflare's trace for each family apart, takes an address only where both agree, and confirms a
change only when a second check a minute later agrees again, `system/network/addresses/`. Its
answer is `/var/lib/machine/addresses.json`, each family `confirmed`, `disputed`, `unknown` or
`none`, the last confirmed address kept through the rest, so a restart loses nothing. Who reads it
and changes a name is still RFC co32d's open question, and nothing reads it yet.

## Its clock

**A machine can keep its clock by chrony, `machine.time.enable`, off by default**, provisional,
chosen by the advisor on 2026-10-26 at the author's request that a cloud's own time source come
first and a third party serve otherwise, `system/time/`: `machine.time.provider` prefers Oracle's
own NTP service or Azure's host clock, the region's resolvers add Alibaba Cloud's and Tencent's
servers in China, and every machine falls back to Cloudflare's over NTS. Google's servers are never
among them, since they smear a leap second and must not mix with sources that do not. Clocks matter
to the cache, whose fetch refuses a pointer more than an hour ahead of its own, docs/cache.md.
