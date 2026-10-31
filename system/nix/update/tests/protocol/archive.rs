//! A driver archive is hashed, checked and unpacked as `driver.sh` did.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::os::unix::fs::PermissionsExt;

use flate2::Compression;
use flate2::write::GzEncoder;
use machine_update::archive::{sha256, unpack};
use machine_update::output::Refusal;
use tar::{Builder, EntryType, Header};

/// One member to put in a test archive.
struct Member<'a> {
	name: &'a str,
	kind: EntryType,
	mode: u32,
	content: &'a [u8],
	link: Option<&'a str>,
}

fn file<'a>(name: &'a str, mode: u32) -> Member<'a> {
	Member { name, kind: EntryType::Regular, mode, content: b"content", link: None }
}

fn archive(members: &[Member]) -> Vec<u8> {
	let mut builder = Builder::new(GzEncoder::new(Vec::new(), Compression::default()));
	for member in members {
		let mut header = Header::new_gnu();
		header.set_entry_type(member.kind);
		header.set_mode(member.mode);
		header.set_size(u64::try_from(member.content.len()).unwrap());
		if let Some(link) = member.link {
			header.set_link_name(link).unwrap();
		}
		builder.append_data(&mut header, member.name, member.content).unwrap();
	}
	builder.into_inner().unwrap().finish().unwrap()
}

fn unpacked(members: &[Member]) -> (tempfile::TempDir, Result<(), Refusal>) {
	let directory = tempfile::tempdir().unwrap();
	let result = unpack(&archive(members), directory.path());
	(directory, result)
}

fn mode(path: &std::path::Path) -> u32 {
	std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn the_hash_is_lowercase_hex() {
	assert_eq!(sha256(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

#[test]
fn the_binary_and_licenses_unpack_with_the_directory_and_binary_at_0755() {
	let (directory, result) = unpacked(&[
		file("driver-machine", 0o700),
		file("LICENSE-MIT", 0o600),
		file("LICENSE-APACHE", 0o666),
	]);
	assert_eq!(result, Ok(()));
	assert_eq!(mode(directory.path()), 0o755);
	assert_eq!(mode(&directory.path().join("driver-machine")), 0o755);
	assert_eq!(std::fs::read(directory.path().join("LICENSE-MIT")).unwrap(), b"content");
	assert_eq!(mode(&directory.path().join("LICENSE-MIT")) & 0o111, 0);
}

#[test]
fn members_may_be_prefixed_and_the_current_directory_is_allowed() {
	let dot =
		Member { name: "./", kind: EntryType::Directory, mode: 0o755, content: b"", link: None };
	let (directory, result) =
		unpacked(&[dot, file("./driver-machine", 0o755), file("./LICENSE-MIT", 0o644)]);
	assert_eq!(result, Ok(()));
	assert!(directory.path().join("driver-machine").is_file());
}

#[test]
fn an_archive_with_licenses_alone_lacks_the_binary() {
	let (_, result) = unpacked(&[file("LICENSE-MIT", 0o644)]);
	assert_eq!(result, Err(Refusal::ArchiveBinary));
}

#[test]
fn a_binary_without_an_executable_bit_is_no_binary() {
	let (_, result) = unpacked(&[file("driver-machine", 0o644)]);
	assert_eq!(result, Err(Refusal::ArchiveBinary));
}

#[test]
fn a_link_in_place_of_the_binary_is_a_link() {
	let link = Member {
		name: "driver-machine",
		kind: EntryType::Symlink,
		mode: 0o755,
		content: b"",
		link: Some("/bin/sh"),
	};
	let (_, result) = unpacked(&[link]);
	assert_eq!(result, Err(Refusal::ArchiveType));
}

#[test]
fn another_member_is_refused_before_a_link_is() {
	let link = Member {
		name: "LICENSE-MIT",
		kind: EntryType::Symlink,
		mode: 0o755,
		content: b"",
		link: Some("x"),
	};
	let (_, result) = unpacked(&[link, file("extra", 0o644)]);
	assert_eq!(result, Err(Refusal::ArchiveMember));
	let (_, result) = unpacked(&[file("driver-machine", 0o755), file("sub/driver-machine", 0o755)]);
	assert_eq!(result, Err(Refusal::ArchiveMember));
}

#[test]
fn a_directory_but_the_current_one_is_a_special_file() {
	let dir = Member {
		name: "driver-machine",
		kind: EntryType::Directory,
		mode: 0o755,
		content: b"",
		link: None,
	};
	let (_, result) = unpacked(&[dir]);
	assert_eq!(result, Err(Refusal::ArchiveType));
}

#[test]
fn bytes_that_are_no_gzip_tar_are_an_invalid_archive() {
	let directory = tempfile::tempdir().unwrap();
	assert_eq!(unpack(b"not an archive", directory.path()), Err(Refusal::Archive));
	assert_eq!(unpack(b"", directory.path()), Err(Refusal::Archive));
	let mut truncated = archive(&[file("driver-machine", 0o755)]);
	truncated.truncate(truncated.len() - 8);
	assert_eq!(unpack(&truncated, directory.path()), Err(Refusal::Archive));
}
