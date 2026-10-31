//! The instance's accepted pointer, `accepted.json`, written whole or not at all. Written by the
//! pointer lane.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process;
use std::time::{SystemTime, UNIX_EPOCH};

/// The accepted pointer's bytes, `None` where none was accepted yet.
pub fn read(file: &Path) -> io::Result<Option<Vec<u8>>> {
	match fs::read(file) {
		Ok(bytes) => Ok(Some(bytes)),
		Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
		Err(error) => Err(error),
	}
}

/// Writes a pointer as the accepted one, through a file beside it renamed over it, mode 0600.
pub fn record(file: &Path, pointer: &[u8]) -> io::Result<()> {
	let directory = file.parent().filter(|parent| !parent.as_os_str().is_empty());
	let directory = directory.unwrap_or_else(|| Path::new("."));
	let nanos =
		SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.subsec_nanos());
	let mut attempt = 0_u32;
	let (pending, mut handle) = loop {
		let pending = directory.join(format!(".accepted.{}.{nanos}.{attempt}", process::id()));
		match OpenOptions::new().write(true).create_new(true).mode(0o600).open(&pending) {
			Ok(handle) => break (pending, handle),
			Err(error) if error.kind() == io::ErrorKind::AlreadyExists && attempt < 100 => {
				attempt += 1;
			}
			Err(error) => return Err(error),
		}
	};
	let written = handle
		.write_all(pointer)
		.and_then(|()| handle.sync_all())
		.and_then(|()| fs::rename(&pending, file));
	if written.is_err() {
		let _ = fs::remove_file(&pending);
	}
	written
}
