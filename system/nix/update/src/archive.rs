//! A driver archive's check and unpacking, the binary and its two licenses alone, as `driver.sh`
//! did. Written by the pointer lane.
#![allow(unused_variables)]

use std::path::Path;

use crate::output::Refusal;

/// The archive's SHA-256, lowercase hex.
pub fn sha256(archive: &[u8]) -> String {
	todo!()
}

/// Unpacks a gzip tar of `driver-machine` and its two licenses alone into an empty directory,
/// refusing a link, a special file or no executable binary, and leaves both mode 0755.
pub fn unpack(archive: &[u8], into: &Path) -> Result<(), Refusal> {
	todo!()
}
