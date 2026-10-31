//! A driver archive's check and unpacking, the binary and its two licenses alone, as `driver.sh`
//! did. Written by the pointer lane.

use std::fs::{self, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

use flate2::read::GzDecoder;
use sha2::{Digest, Sha256};
use tar::EntryType;

use crate::output::Refusal;

/// The archive's SHA-256, lowercase hex.
pub fn sha256(archive: &[u8]) -> String {
	hex::encode(Sha256::digest(archive))
}

/// Unpacks a gzip tar of `driver-machine` and its two licenses alone into an empty directory,
/// refusing a link, a special file or no executable binary, and leaves both mode 0755.
pub fn unpack(archive: &[u8], into: &Path) -> Result<(), Refusal> {
	let members = listing(archive).map_err(|_| Refusal::Archive)?;
	if members.iter().any(|(name, _)| !allowed(name)) {
		return Err(Refusal::ArchiveMember);
	}
	if members.iter().any(|(name, kind)| !plain(name, *kind)) {
		return Err(Refusal::ArchiveType);
	}
	extract(archive, into).map_err(|_| Refusal::ArchiveBinary)?;
	let binary = into.join("driver-machine");
	let executable = fs::symlink_metadata(&binary)
		.is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0);
	if !executable {
		return Err(Refusal::ArchiveBinary);
	}
	fs::set_permissions(into, fs::Permissions::from_mode(0o755))
		.map_err(|_| Refusal::ArchiveBinary)?;
	fs::set_permissions(&binary, fs::Permissions::from_mode(0o755))
		.map_err(|_| Refusal::ArchiveBinary)
}

/// Every member's name as stored and its type, as `tar -tzf` and `tar -tvzf` listed them.
fn listing(archive: &[u8]) -> io::Result<Vec<(String, EntryType)>> {
	let mut tar = tar::Archive::new(GzDecoder::new(archive));
	let mut members = Vec::new();
	for entry in tar.entries()? {
		let entry = entry?;
		let kind = entry.header().entry_type();
		if kind == EntryType::XGlobalHeader {
			continue;
		}
		members.push((String::from_utf8_lossy(&entry.path_bytes()).into_owned(), kind));
	}
	// The gzip stream is read to its end, as the pipe tar read from failed on a damaged one.
	io::copy(&mut tar.into_inner(), &mut io::sink())?;
	Ok(members)
}

fn allowed(name: &str) -> bool {
	matches!(
		name,
		"driver-machine"
			| "LICENSE-MIT"
			| "LICENSE-APACHE"
			| "./"
			| "./driver-machine"
			| "./LICENSE-MIT"
			| "./LICENSE-APACHE"
	)
}

/// A regular file, or the `./` directory.
fn plain(name: &str, kind: EntryType) -> bool {
	kind == EntryType::Regular || (kind == EntryType::Directory && name == "./")
}

/// Writes each regular member under its name without the owner and the permissions it carries,
/// but for the bits that make it executable.
fn extract(archive: &[u8], into: &Path) -> io::Result<()> {
	let mut tar = tar::Archive::new(GzDecoder::new(archive));
	for entry in tar.entries()? {
		let mut entry = entry?;
		if entry.header().entry_type() != EntryType::Regular {
			continue;
		}
		let name = String::from_utf8_lossy(&entry.path_bytes()).into_owned();
		let name = name.strip_prefix("./").unwrap_or(&name);
		let mode = entry.header().mode()? & 0o755;
		let mut file = OpenOptions::new()
			.write(true)
			.create(true)
			.truncate(true)
			.mode(mode)
			.open(into.join(name))?;
		let mut content = Vec::new();
		entry.read_to_end(&mut content)?;
		io::Write::write_all(&mut file, &content)?;
	}
	Ok(())
}
