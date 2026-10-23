# The builder and the local machine

Two containers in Docker on a developer's computer, decided with the author on 2026-10-22 for
RFC n0o4l: one that builds every machine's system, so no machine builds its own, and one that is a
test machine, so the driver can be developed with no network beyond `localhost`. Both are this
repository's, since neither carries a secret.

```sh
mise run builder up     # or down
mise run local up       # starts it, or switches it to this checkout's local/; or down
```

|               | Builder                     | Local machine                                        |
| ------------- | --------------------------- | ---------------------------------------------------- |
| Container     | `monoflake-builder`         | `monoflake-local`                                    |
| Image         | `nixos/nix`, pinned         | `monoflake-empty:1`, an empty root it imports        |
| Volumes       | `monoflake-builder`, `/nix` | `monoflake-local-nix`, `/nix`                        |
|               |                             | `monoflake-local-state`, `/var/lib`                  |
| sshd, as root | `localhost:2221`            | `localhost:2222`                                     |
| The entry     |                             | `localhost:8080`, `monoflake-entry`'s `36879` inside |
| What it runs  | sshd, Nix as a remote store | the machine module and `local/`, systemd first       |
| Scripts       | `scripts/builder.res`       | `scripts/local.res`                                  |

`down` stops and removes a container and keeps its volumes, so `up` starts again where it left
off: the builder's store, and the local machine's store, disk, driver state and sshd host key. A
local machine running without a port this script publishes is started again rather than switched,
as Docker publishes a port only when it starts a container.
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

Its entry is published on `localhost:8080`, plain HTTP, and hands a request to the deployment the
leftmost two labels of its host name, `app-<id>.b<binding>`, the rest passed over, RFC n0o4l:

```sh
curl -H 'Host: app-1.b1.local' http://localhost:8080/
```

A host naming no deployment is answered 404, and one naming a deployment not running 503. A machine
of its own listens on loopback alone, where the tunnel in front of it reaches it.

The entry is a unit of its own, `monoflake-entry`, the command `entry` of the binary the driver
runs, reading where a deployment runs from containerd alone, so it serves on while the driver is
stopped, RFC rmll5; `dev local` restarts both. Its listener is held by `monoflake-entry.socket`, so a
connection made while it restarts waits for it rather than being refused, and it answers what it has
begun before it stops, RFC ehm48.
