//! The two pointers' protocols, a system's and a driver's, as `protocol.sh` and
//! `driver-protocol.sh` held them. Written by the pointer lane.
#![allow(unused_variables)]

use crate::output::Refusal;

/// A system pointer, `{"at", "machine", "path", "run"}`, every field a string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SystemPointer {
	/// The machine it is written for.
	pub machine: String,
	/// The system's store path, `/nix/store/<32 base32>-<name>`.
	pub path: String,
	/// When CI signed it, `YYYY-MM-DDTHH:MM:SSZ`, which orders pointers as text.
	pub at: String,
	/// The CI run that wrote it.
	pub run: String,
}

/// One architecture's archive of a driver release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Archive {
	/// An `https://` URL, or `build/driver/<sha256>.tar.gz` in the bucket.
	pub url: String,
	/// The archive's SHA-256, lowercase hex.
	pub sha256: String,
}

/// A driver pointer, `{"archives", "at", "machine", "run", "version"}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DriverPointer {
	/// The machine it is written for.
	pub machine: String,
	/// The release, the directory it is installed as.
	pub version: String,
	/// When it was signed, as a system pointer's.
	pub at: String,
	/// The run that wrote it.
	pub run: String,
	/// The `x86_64-linux` archive.
	pub x86_64: Archive,
	/// The `aarch64-linux` archive.
	pub aarch64: Archive,
}

impl DriverPointer {
	/// The archive for a Nix system, `None` for any other than the two.
	pub fn archive(&self, architecture: &str) -> Option<&Archive> {
		todo!()
	}
}

/// Reads a system pointer, refusing it as `update_pointer` did, `now` the machine's clock.
pub fn system(bytes: &[u8], machine: &str, now: i64) -> Result<SystemPointer, Refusal> {
	todo!()
}

/// Reads a driver pointer, refusing it as `update_driver_pointer` did, a bucket build refused
/// unless `builds`.
pub fn driver(
	bytes: &[u8],
	machine: &str,
	now: i64,
	builds: bool,
) -> Result<DriverPointer, Refusal> {
	todo!()
}
