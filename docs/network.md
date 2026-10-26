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
