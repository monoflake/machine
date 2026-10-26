# AGENTS.md

NixOS for running containers, the module every machine of a deployment imports, MIT. Read it after
the workspace's `AGENTS.md`; it holds only what is this repository's own, and its rules are in
[docs/](docs/).

## What belongs here

**What is generic about a machine sinks into this repository; a deployment's repository keeps only
its private specifics**, decided by the author on 2026-10-26. An option, its mechanics, its
defaults, its validation, a preset of public facts such as a resolver's or a time source's
address, and a derivation that takes a deployment's data are written here; the deployment chooses
values and holds its data, as monoflake/cloud does. Nothing private enters this repository: no
name of a deployment's machine, no address, no port range a router forwards, no tailnet's name and
no fact of a provider's account.
