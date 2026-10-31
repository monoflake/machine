//! The instance's accepted pointer, `accepted.json`, written whole or not at all. Written by the
//! pointer lane.
#![allow(unused_variables)]

use std::io;
use std::path::Path;

/// The accepted pointer's bytes, `None` where none was accepted yet.
pub fn read(file: &Path) -> io::Result<Option<Vec<u8>>> {
	todo!()
}

/// Writes a pointer as the accepted one, through a file beside it renamed over it, mode 0600.
pub fn record(file: &Path, pointer: &[u8]) -> io::Result<()> {
	todo!()
}
