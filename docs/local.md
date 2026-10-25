# The builder and the local machine

Two containers in Docker on a developer's computer, decided with the author on 2026-10-22 for
RFC n0o4l: one that builds every machine's system, so no machine builds its own, and one that is a
test machine, so the driver can be developed with no network beyond `localhost`. Both are this
repository's, since neither carries a secret.

```sh
mise run builder up     # or down
mise run local up       # starts it, or switches it to this checkout's local/; or down
```

|               | Builder                     | Local machine                                             |
| ------------- | --------------------------- | --------------------------------------------------------- |
| Container     | `machine-builder`           | `machine-local`                                           |
| Image         | `nixos/nix`, pinned         | `machine-empty:1`, an empty root it imports               |
| Volumes       | `machine-builder`, `/nix`   | `machine-local-nix`, `/nix`                               |
|               |                             | `machine-local-state`, `/var/lib`                         |
| sshd, as root | `localhost:2221`            | `localhost:2222`                                          |
| The entry     |                             | `localhost:8080`, `driver-machine-entry`'s `36879` inside |
|               |                             | `localhost:36879`, the same, the port a control reaches   |
| The driver    |                             | `localhost:37483`, `driver-machine`'s own port            |
| What it runs  | sshd, Nix as a remote store | the machine module and `local/`, systemd first            |
| Scripts       | `scripts/builder.res`       | `scripts/local.res`                                       |

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
boot loader, no tailnet, Docker's address, and `/data` btrfs with simple quotas on a sparse loop
file in the state volume. Docker gives it a real machine's public nameservers, by `--dns`, as the
fence drops Docker's own resolver to a container, and its name for this computer,
`host.docker.internal`, by `--add-host`; `scripts/local.res` passes both. `/etc/resolv.conf` and
`/etc/hosts` are Docker's files, and no unit rewrites either. It runs privileged with a cgroup
namespace of its own, so containerd and the driver's containers run inside it.

NixOS's firewall runs in it as on a real machine, with Docker's `eth0` trusted in the tailnet's
place, since only Docker's own network and the ports published on this computer's loopback reach
it. So the driver's bridges are held as they are on a real machine, and conform, which
`machine.conform` enables here, finds its entry open on `conform0` alone, docs/fence.md. Docker
Desktop's kernel loads both NixOS's firewall and the fence, its reverse path check by `fib`
included, in a container's own network namespace, tried on 2026-10-25.

At first boot it makes its binding token, `/var/lib/driver-machine/binding`, which never leaves
it but by ssh. The driver runs what monoflake/driver's `mise run dev local` copies in, and takes
`file:` artifacts from `/var/lib/driver-machine/artifacts`. Its sshd's host key is the container's
own, so `dev local` does not check it, as the tools for a virtual machine on `localhost` do not.

Its entry is published on `localhost:8080`, plain HTTP, and hands a request to the deployment the
leftmost two labels of its host name, `<id>.b<binding>`, its id in 8 lowercase hex digits as
platform's RFC b8f35 writes it and the deploy printed it, the rest passed over, RFC n0o4l:

```sh
curl -H 'Host: 0a1b2c3d.b1.local' http://localhost:8080/
```

A host naming no deployment is answered 404, and one naming a deployment not running 503. Every
machine's entry listens on every address, as its driver does, so a bound host's control reaches
both at its private address; the firewall keeps both ports from the public interface.

The entry is a unit of its own, `driver-machine-entry`, the command `entry` of the binary the
driver runs, reading where a deployment runs from containerd alone, so it serves on while the
driver is stopped, RFC rmll5; `dev local` restarts both. Its listener is held by
`driver-machine-entry.socket`, so a connection made while it restarts waits for it rather than
being refused, and it answers what it has begun before it stops, RFC ehm48.

## Bound to a control on this computer

The driver's management is published on `localhost:37483` and the entry on `localhost:36879`, so a
control run here, `wrangler dev`, reaches both as it reaches a bound host's private address through
its tunnel, RFC rxmd9. The local machine is bound to it as any host is, its control reached from
inside at `host.docker.internal`, the one origin `machine.driver.plain` lets the driver fetch an
artifact from over plain HTTP:

```sh
ssh -p 2222 root@localhost
/var/lib/driver-machine/dev/driver-machine bind --insecure http://host.docker.internal:8787 < token
```

`bind` writes the binding's token, the tunnel's token where the control answered one, and the
host's private address last, under `/var/lib/driver-machine/state/bound`, root's alone.
`machine.tunnel.bound.enable` then holds the address on the interface `tunnel0`, where the driver
and the entry answer on their ports, and runs the named tunnel `bound-tunnel` by the token; each
waits until the host is bound, and `bound.path` starts both again and reloads the driver's tokens
when it is bound again. A control on this computer holds no Cloudflare credential and answers no
tunnel, so none runs.
