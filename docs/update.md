# Signed system updates

`machine.update.enable` makes a machine take its system from CI's signed pointer, RFC oej2a.
Set its bucket, UTC `at` time, `pointerPublicKey`, `nixPublicKey`, `credentialsFile` and
`endpointFile`. The last two are runtime paths outside the store, rendered root only by sops-nix.
The credentials file is an AWS shared credentials file whose `[systems]` profile holds
`aws_access_key_id` and `aws_secret_access_key`; the endpoint file holds the HTTPS endpoint URL
alone. Neither file's contents enters evaluation. The daemon and updater receive only the
credentials file path in their environment. The endpoint is read only
at runtime and never added to nix.conf or a unit.

The persistent daily timer starts `update-now@system` at `at` UTC. Starting that service by hand
runs the same check. Its template reserves other instances for later channels and presently
accepts only `system`. The service survives its own switch and keeps accepted state under
`/var/lib/machine-update/system`, mode 0700.

The updater fetches `pointer/<machine>` before its signature. It verifies identity `ci` in
namespace `system-pointer`, then requires exactly the machine name, store path, UTC `at` and
nonempty `run`. Invalid signatures, a driver namespace, another machine, malformed fields and
times more than an hour ahead are refused. The accepted pointer prevents rollback to an older
`at`, or an equal `at` from another run. The same accepted pointer is not switched again, even
after a manual rollback. An accepted run cannot change its path. The same running
system ends the run without realizing or switching, recording the pointer if needed.

A different system is realized from the public NixOS cache and the bucket, requiring signatures
from their trusted Nix keys. The global substituters stay unchanged. This command sets `max-jobs`
to zero and clears `builders`, so the machine never builds, locally or remotely. Missing
substitutes fail the update. The realization roots the system until its system profile holds it.
Only a successful switch records the pointer, by an atomic rename. Fetch, verification and
realization failures leave the running system and accepted state untouched. A failed switch
keeps the accepted state and attempts to restore the previous profile and system; NixOS activation
is not transactional, so restoration can itself fail or leave effects from partial activation.

The fetch executable accepts `system --dry-run` with the service's configuration and runtime
paths. It fetches and verifies the pointer, applies the rollback checks and reports whether the
system is already running or would switch. It realizes nothing and writes no accepted state.
Each stage is logged with `update:`; a failed realise or switch shows its tool's last lines with
the endpoint's host and the key pair masked. `machine-update-check` runs this dry run by hand with the service's
paths.

The old `system/nix/cache/` mechanism stays frozen until monoflake/cloud's reset. Both mechanisms
cannot be enabled on one machine. Its builder and fetch documentation remains in [cache.md](cache.md).
The driver's existing release lock remains in force until its separate pointer channel lands.
