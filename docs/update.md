# Signed updates

`machine.update.enable` makes a machine take its system from CI's signed pointer, RFC oej2a.
Set its bucket, UTC `at` time, `pointerPublicKey`, `nixPublicKey`, `credentialsFile` and
`endpointFile`. The last two are runtime paths outside the store, rendered root only by sops-nix.
The credentials file is an AWS shared credentials file whose `[systems]` profile holds
`aws_access_key_id` and `aws_secret_access_key`; the endpoint file holds the HTTPS endpoint URL
alone. Neither file's contents enters evaluation. The daemon and updater receive only the
credentials file path in their environment. The endpoint is read only
at runtime and never added to nix.conf or a unit.

The persistent daily timer starts `update-now@system` at `at` UTC. Starting that service by hand
runs the same check. Its template also accepts `driver` when the driver channel is enabled. The service survives its own
switch and keeps accepted state under
`/var/lib/machine-update/system`, mode 0700.

The updater fetches `pointer/system/<machine>` before its signature. It verifies identity `ci` in
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
The release lock still supplies frozen machines until monoflake/cloud's reset.

## Driver channel

`machine.driver.channel = true` selects the signed driver channel instead of `package` or
`override` and requires `machine.update.enable`. Both driver services run
`/var/lib/driver/current/driver-machine` with the system's runtime arguments. Until that binary
exists, the services remain inactive. The root owned directory and installed versions are mode
0755 so the entry's dynamic user can read and execute them.

The persistent `update-now@driver` timer uses the same `machine.update.at` UTC window. Its state
is separate under `/var/lib/machine-update/driver`, mode 0700. It uses the system updater's bucket,
endpoint, credentials and public key, fetching `pointer/driver/<machine>` before its signature.
An absent driver pointer or signature is nothing to do and leaves installed files and state alone.
The signature uses namespace `driver-pointer` and identity `ci`. A test machine alone may set
`machine.update.testSigner` to trust identity `mac` for that namespace; system pointers accept
`ci` alone. The pointer contains exactly
`machine`, `version`, `archives`, `at` and `run`. Both Linux architectures need an archive URL and a SHA-256. The URL is either HTTPS or exactly
`build/driver/<sha256>.tar.gz` with that archive's hash.
`machine.update.driverBuilds` defaults to false and is the machine's own guard that a production
machine takes Releases alone, set true only on a test ring's machine independently of `testSigner`.
The URL only locates the archive; the signed SHA-256 is trusted. Malformed fields, another machine and times more than one hour ahead are refused. Versions use letters,
digits, dots, plus signs and hyphens; `.`, `..`, `current` and `previous` are reserved directory
names and refused.

The pointer's `at` and `run` are what is monotonic, never the version, so a ring may deliberately
move a machine to an older release; this is a design choice, not a rollback hole. Older times and
equal times from another run are refused. An accepted pointer cannot change and is never applied
again, including after a manual rollback. A newer pointer naming the current version records its
state without downloading or restarting.

A new version downloads over HTTPS without credentials, or from its build key with the same
bucket credentials and endpoint as the pointers, verifies the hash and unpacks
regular release files into a temporary directory under `/var/lib/driver`. It requires an
executable `driver-machine`, installs `/var/lib/driver/<version>`, atomically replaces `current`,
and points `previous` at the version it replaced. Both services restart and must become active
within a bounded wait. Failure restores the links and restarts again without recording state.
On the first install there is no earlier binary, so failure removes `current` and `previous`,
stops both services and does not wait for them to become active. Only success records the pointer
and removes all version directories except `current` and exactly one `previous`.
An installed build outlives its object in the bucket; an expired archive refuses a new install
without changing any installed version, link or accepted state.

`machine-update-check driver` fetches and verifies with the service's paths and reports whether
it would install, changing no installed files, links or accepted state. Each stage uses `update:`
output, masking runtime access values in tool diagnostics. Root can run `machine-driver-rollback`
to swap `current` and `previous` and restart both services. It leaves accepted pointer state alone;
a failed restart restores the original links and attempts another restart.

## Nudge

`machine.nudge.key` and `machine.nudge.expiry` come from monoflake/cloud. Both default to null;
setting the key requires its UTC `YYYYMMDDZ` expiry and `machine.update.enable`. The key creates
the passwordless system user `nudge`, whose restricted SSH key and shell run only the forced
command. This adds no firewall port and changes no sshd setting.

`ssh nudge@<machine> system` starts `update-now@system.service` and waits for its result. It prints
the unit's `Result` and the current system path, returning the start's exit status even on failure.
Exactly `system` and `driver` are accepted; an empty command, arguments, whitespace variants and
all other commands are refused. The account has no terminal or forwarding and may only start
those two units through polkit, with no sudo permission. It reads no journal or update state.
`driver` prints its unit's `Result` followed by `readlink /var/lib/driver/current`.
