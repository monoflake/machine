# Layers

**A machine is two layers, the base every machine takes and the fleet's above it**, decided by the
author on 2026-10-31. `nixosModules.base`, `system/base/`, is what the fleet's machines and a
deployment's self-hosted runners share: the release with `pkgs.unstable` and `pkgs.latest`,
[releases.md](releases.md), UTC and a small journal, a console on the serial line and the screen,
the degraded mark, nftables with fixed nameservers, BBR over fq with one cap on every buffer, SSH by
key on the tailnet, Tailscale with its resolver and routes refused, chrony where asked, Nix with
flakes and no channels, the tools for hands, and a provider's seed where it gives no DHCP.
`nixosModules.machine` imports it and adds the fleet's: the names and labels of a failure domain,
GRUB and the data disk, zswap in front of a swap file there, public SSH until the tailnet is
healthy, the tailnet's auth key and roles, the driver, its containers, fence and tunnel, the
cache, collection, upgrade and signed updates. **No option of the base reads an option of the
fleet's**, so a runner sets none of a machine's names, provider or account: it is in no failure
domain.

**The swap is sized by one formula, `system/base/swap.nix`**, read as `machine.swap.size` and
exported as `lib.swap`: the fleet keeps it as a swap file on the data disk behind zswap, and a
machine with no data disk sets `machine.swap.zram`, a zram device of that size compressed by
`machine.swap.compressor`. **The boot loader is no layer's choice**: the fleet's is GRUB, and a
deployment's runner chooses its own.

**Splitting a module between the layers changes no fleet machine's system**: every toplevel's
derivation was compared before and after the split of 2026-10-31 and came out the same. A list one
layer adds to and the other too keeps the order it had, as `--accept-dns=false` is put first by
`mkBefore`, the fleet's own flags following it.
