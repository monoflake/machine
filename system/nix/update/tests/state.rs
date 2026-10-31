//! The accepted pointer is read whole and written whole.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::os::unix::fs::PermissionsExt;

use machine_update::state::{read, record};

#[test]
fn a_state_never_written_reads_as_none() {
	let directory = tempfile::tempdir().unwrap();
	assert_eq!(read(&directory.path().join("accepted.json")).unwrap(), None);
}

#[test]
fn a_recorded_pointer_reads_back_in_mode_0600_with_no_file_left_beside_it() {
	let directory = tempfile::tempdir().unwrap();
	let file = directory.path().join("accepted.json");
	record(&file, b"first").unwrap();
	record(&file, b"second").unwrap();
	assert_eq!(read(&file).unwrap().as_deref(), Some(&b"second"[..]));
	assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
	assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
}

#[test]
fn recording_into_a_missing_directory_fails() {
	let directory = tempfile::tempdir().unwrap();
	assert!(record(&directory.path().join("missing/accepted.json"), b"x").is_err());
}

#[test]
fn a_state_that_is_a_directory_is_an_error_not_none() {
	let directory = tempfile::tempdir().unwrap();
	assert!(read(directory.path()).is_err());
}
