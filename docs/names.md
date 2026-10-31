# Names and labels

**Every machine has three names and three labels**, decided by the author on 2026-10-29.
The option shape is provisional, chosen by the advisor the same day, in `system/options.nix`.
A deployment supplies its own values in its private repository. This public repository holds
only the rules and invented examples.

`machine.name` is the Network Name, the unique identifier of the machine and its tailnet name.
It is required with no default. It starts with a lowercase letter, contains only lowercase
letters, digits and hyphens, and is at most 63 characters long. The deployment is responsible
for uniqueness across its machines.

`machine.hostname` is the static hostname an SSH shell shows in `root@...`. It has the same
shape as the Network Name and defaults to it. `machine.prettyName` is the display name and the
DHCP host name reported to the LAN router. It defaults to the Network Name with its first letter
capitalized and contains only letters of either case, digits and hyphens, so DHCP can carry it.
It is nonempty and has no additional length or first character restriction.

`system/names.nix` sets the static hostname, the tailnet's `--hostname` flag and
`PRETTY_HOSTNAME` in `/etc/machine-info`. Where dhcpcd runs, it adds `hostname` with the pretty
name to its configuration beside the network module's `nohook resolv.conf`.
If systemd-networkd ran DHCP, its equivalent would be `[DHCPv4] Hostname=`.
The seed path, `system/base/seed`, uses static addresses and no DHCP, so it sends no DHCP
host name. No live DHCP test is required; the author accepts this as feasible in theory.

**The cache keys machines by `machine.name`, never by the static hostname**, including its
inventory check, pointers, builder identity, self runs and the host a builder reaches.
A machine can therefore change its static hostname without changing its cache identity.

`machine.region` and `machine.provider` are required enums whose closed lists live once in
`system/labels.nix`. A provider is the vendor's lowercase name, or `selfhost` for one's own
machines. A new region or provider is legal only after that file is edited. The flake exports
that same data as `lib.labels`, beside `lib.fleet`, so a deployment reads the lists from the
commit it locks.

`machine.account` is a required nonempty string. Its value is never verified.
**A failure domain is the same provider and the same account**; the same account string at two
providers denotes two domains. Nothing computes failure domains yet. A local container's labels
are placeholders nothing reads.

`system/names-test.nix` evaluates the names, validation, labels and rendered settings without a
live network. The cache's eval tests cover a static hostname that differs from the Network Name.
