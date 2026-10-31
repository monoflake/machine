//! What the module hands the program, `MACHINE_UPDATE_CONFIG`'s JSON as `default.nix` writes it,
//! and where on the machine each thing lives.

use std::path::{Path, PathBuf};

use serde::Deserialize;

/// The module's JSON, read once at start.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
	/// The bucket's name, or `file:///<directory>` for a bucket on disk.
	pub bucket: String,
	/// The machine's name, which each pointer must carry.
	pub machine: String,
	/// The file holding the `[systems]` profile's key pair.
	pub credentials_file: PathBuf,
	/// The file holding the bucket's HTTPS origin.
	pub endpoint_file: PathBuf,
	/// The allowed signers file for `system-pointer`, the CI's key as principal `ci`.
	pub signers: PathBuf,
	/// The allowed signers file for `driver-pointer`, `ci` and on a test machine `mac`.
	pub driver_signers: PathBuf,
	/// Whether this machine takes its driver by pointer.
	pub driver_channel: bool,
	/// Whether a driver pointer may name a build in the bucket.
	pub driver_builds: bool,
	/// The machine's Nix system, as `x86_64-linux`, which picks the driver's archive.
	pub architecture: String,
	/// The keys a narinfo may be signed by, space separated, as `trusted-public-keys` holds them.
	pub trusted: String,
}

/// The run's instance, the unit `update-now@<instance>` that started it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Instance {
	/// The machine's NixOS system.
	System,
	/// The machine's driver, monoflake/driver's driver-machine.
	Driver,
}

/// Where the run reads and writes on the machine, each fixed in production and moved in a test.
#[derive(Debug, Clone)]
pub struct Paths {
	/// The instance's state directory, `STATE_DIRECTORY`, holding `accepted.json`.
	pub state: PathBuf,
	/// The link to the running system.
	pub current_system: PathBuf,
	/// The system profile, whose generations sit beside it.
	pub profile: PathBuf,
	/// The driver's directory, its versions with `current`, `previous` and `.update-lock`.
	pub driver: PathBuf,
	/// The Nix daemon's socket.
	pub daemon: PathBuf,
}

impl Paths {
	/// The machine's own paths, the state directory as systemd gives it.
	pub fn machine(state: &Path) -> Self {
		Self {
			state: state.to_owned(),
			current_system: PathBuf::from("/run/current-system"),
			profile: PathBuf::from("/nix/var/nix/profiles/system"),
			driver: PathBuf::from("/var/lib/driver"),
			daemon: PathBuf::from("/nix/var/nix/daemon-socket/socket"),
		}
	}

	/// The accepted pointer's file.
	pub fn accepted(&self) -> PathBuf {
		self.state.join("accepted.json")
	}
}
