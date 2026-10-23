# The builder and the local machine

Two containers in Docker on a developer's computer, decided with the author on 2026-10-22 for
RFC n0o4l: one that builds every machine's system, so no machine builds its own, and one that is a
test machine, so the driver can be developed with no network beyond `localhost`. Both are this
repository's, since neither carries a secret.

```sh
mise run builder up     # or down
mise run local up       # starts it, or switches it to this checkout's local/; or down
```

|               | Builder                     | Local machine                                  |
| ------------- | --------------------------- | ---------------------------------------------- |
| Container     | `monoflake-builder`         | `monoflake-local`                              |
| Image         | `nixos/nix`, pinned         | `monoflake-empty:1`, an empty root it imports  |
| Volumes       | `monoflake-builder`, `/nix` | `monoflake-local-nix`, `/nix`                  |
|               |                             | `monoflake-local-state`, `/var/lib`            |
| sshd, as root | `localhost:2221`            | `localhost:2222`                               |
| What it runs  | sshd, Nix as a remote store | the machine module and `local/`, systemd first |
| Scripts       | `scripts/builder.res`       | `scripts/local.res`                            |

`down` stops and removes a container and keeps its volumes, so `up` starts again where it left
off: the builder's store, and the local machine's store, disk, driver state and sshd host key.
Dropping a volume with `docker volume rm` starts that part afresh.

## The builder

A `nixos/nix` container with its store in a volume and the sandbox on. On Apple silicon it builds
`x86_64-linux` as well as `aarch64-linux`, by Docker Desktop's Rosetta, and the paths it builds
are a native machine's. A system is evaluated on the developer's computer, built in the builder,
and copied from it to the machine through the computer, `Builder.deployed`; the machine then sets
its system profile and switches, and builds nothing. Its sshd authorizes the computer's own SSH
public keys, `ssh-add -L` and `~/.ssh/id_*.pub`, read at each `up`.

Nix reaches each container through an ssh configuration written to a temporary directory for the
run, naming the container's port and the host key read from it, and including the computer's own
`~/.ssh/config` after it; nothing under the home is written.

## The local machine

`local/` is the module that makes this repository's machine a container: `boot.isContainer`, no
boot loader, no tailnet or firewall, Docker's address and resolver, and `/data` btrfs with simple
quotas on a sparse loop file in the state volume. It runs privileged with a cgroup namespace of its
own, so containerd and the driver's containers run inside it.

At first boot it makes its binding token, `/var/lib/monoflake/binding`, which never leaves it
but by ssh. The driver runs what monoflake/driver's `mise run dev local` copies in, and takes
`file:` artifacts from `/var/lib/monoflake/artifacts`. Its sshd's host key is the container's own,
so `dev local` does not check it, as the tools for a virtual machine on `localhost` do not.
