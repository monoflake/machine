//! The two pointers' protocols, a system's and a driver's, as `protocol.sh` and
//! `driver-protocol.sh` held them. Written by the pointer lane.

use serde_json::{Map, Value};
use time::{Date, Month, PrimitiveDateTime, Time};

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
		match architecture {
			"x86_64-linux" => Some(&self.x86_64),
			"aarch64-linux" => Some(&self.aarch64),
			_ => None,
		}
	}
}

/// Reads a system pointer, refusing it as `update_pointer` did, `now` the machine's clock.
pub fn system(bytes: &[u8], machine: &str, now: i64) -> Result<SystemPointer, Refusal> {
	let value: Value = serde_json::from_slice(bytes).map_err(|_| Refusal::Fields)?;
	let object = exact_keys(&value, &["at", "machine", "path", "run"]).ok_or(Refusal::Fields)?;
	let at = string(object, "at", Refusal::Fields)?;
	let written_for = string(object, "machine", Refusal::Fields)?;
	let path = string(object, "path", Refusal::Fields)?;
	let run = string(object, "run", Refusal::Fields)?;
	if written_for != machine {
		return Err(Refusal::Machine);
	}
	if !store_path(path) {
		return Err(Refusal::Path);
	}
	check_time(at, now)?;
	check_run(run)?;
	Ok(SystemPointer {
		machine: written_for.to_owned(),
		path: path.to_owned(),
		at: at.to_owned(),
		run: run.to_owned(),
	})
}

/// Reads a driver pointer, refusing it as `update_driver_pointer` did, a bucket build refused
/// unless `builds`.
pub fn driver(
	bytes: &[u8],
	machine: &str,
	now: i64,
	builds: bool,
) -> Result<DriverPointer, Refusal> {
	let fields = Refusal::DriverFields;
	let value: Value = serde_json::from_slice(bytes).map_err(|_| fields)?;
	let object =
		exact_keys(&value, &["archives", "at", "machine", "run", "version"]).ok_or(fields)?;
	let written_for = string(object, "machine", fields)?;
	let at = string(object, "at", fields)?;
	let run = string(object, "run", fields)?;
	let version = string(object, "version", fields)?;
	let archives = object.get("archives").ok_or(fields)?;
	let archives = exact_keys(archives, &["aarch64-linux", "x86_64-linux"]).ok_or(fields)?;
	let aarch64 = archive_fields(archives, "aarch64-linux")?;
	let x86_64 = archive_fields(archives, "x86_64-linux")?;
	if !builds && [&aarch64, &x86_64].iter().any(|(url, _)| !url.starts_with("https://")) {
		return Err(Refusal::Builds);
	}
	for (url, sha256) in [&aarch64, &x86_64] {
		if !(remote(url) || *url == format!("build/driver/{sha256}.tar.gz")) {
			return Err(fields);
		}
	}
	if written_for != machine {
		return Err(Refusal::Machine);
	}
	if !release(version) {
		return Err(Refusal::Version);
	}
	check_time(at, now)?;
	check_run(run)?;
	let archive = |(url, sha256): (&str, &str)| Archive {
		url: url.to_owned(),
		sha256: sha256.to_ascii_lowercase(),
	};
	Ok(DriverPointer {
		machine: written_for.to_owned(),
		version: version.to_owned(),
		at: at.to_owned(),
		run: run.to_owned(),
		x86_64: archive(x86_64),
		aarch64: archive(aarch64),
	})
}

/// The object a value is when its keys are exactly `keys`, as jq's `keys == [...]` held.
fn exact_keys<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Map<String, Value>> {
	let object = value.as_object()?;
	(object.len() == keys.len() && keys.iter().all(|key| object.contains_key(*key))).then_some(object)
}

fn string<'a>(
	object: &'a Map<String, Value>,
	key: &str,
	refusal: Refusal,
) -> Result<&'a str, Refusal> {
	object.get(key).and_then(Value::as_str).ok_or(refusal)
}

/// One architecture's url and sha256 as written, the sha256 sixty-four hex digits of either case.
fn archive_fields<'a>(
	archives: &'a Map<String, Value>,
	architecture: &str,
) -> Result<(&'a str, &'a str), Refusal> {
	let fields = Refusal::DriverFields;
	let object = archives.get(architecture).ok_or(fields)?;
	let object = exact_keys(object, &["sha256", "url"]).ok_or(fields)?;
	let url = string(object, "url", fields)?;
	let sha256 = string(object, "sha256", fields)?;
	if sha256.len() != 64 || !sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
		return Err(fields);
	}
	Ok((url, sha256))
}

/// `https://` and then something, none of it whitespace.
fn remote(url: &str) -> bool {
	url
		.strip_prefix("https://")
		.is_some_and(|rest| !rest.is_empty() && !rest.chars().any(char::is_whitespace))
}

/// `/nix/store/` and thirty-two base32 characters, a hyphen and a name.
fn store_path(path: &str) -> bool {
	let Some((hash, name)) =
		path.strip_prefix("/nix/store/").and_then(|rest| rest.split_at_checked(32))
	else {
		return false;
	};
	let Some(name) = name.strip_prefix('-') else {
		return false;
	};
	hash.bytes().all(|byte| byte.is_ascii_digit() || byte.is_ascii_lowercase())
		&& !name.is_empty()
		&& name.bytes().all(|byte| {
			byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'.' | b'_' | b'?' | b'=' | b'-')
		})
}

fn release(version: &str) -> bool {
	!version.is_empty()
		&& version
			.bytes()
			.all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'+' | b'-'))
		&& !matches!(version, "." | ".." | "current" | "previous")
}

/// The time a real UTC second written whole, no more than an hour past `now`.
fn check_time(at: &str, now: i64) -> Result<(), Refusal> {
	let epoch = epoch(at).ok_or(Refusal::Time)?;
	if epoch > now.saturating_add(3600) {
		return Err(Refusal::Ahead);
	}
	Ok(())
}

fn epoch(at: &str) -> Option<i64> {
	let bytes = at.as_bytes();
	let separators = [(4, b'-'), (7, b'-'), (10, b'T'), (13, b':'), (16, b':'), (19, b'Z')];
	if bytes.len() != 20 || separators.iter().any(|(index, byte)| bytes.get(*index) != Some(byte)) {
		return None;
	}
	let number = |from: usize, to: usize| -> Option<i32> {
		let digits = at.get(from..to)?;
		digits.bytes().all(|byte| byte.is_ascii_digit()).then(|| digits.parse().ok())?
	};
	let month = Month::try_from(u8::try_from(number(5, 7)?).ok()?).ok()?;
	let date =
		Date::from_calendar_date(number(0, 4)?, month, u8::try_from(number(8, 10)?).ok()?).ok()?;
	let time = Time::from_hms(
		u8::try_from(number(11, 13)?).ok()?,
		u8::try_from(number(14, 16)?).ok()?,
		u8::try_from(number(17, 19)?).ok()?,
	)
	.ok()?;
	Some(PrimitiveDateTime::new(date, time).assume_utc().unix_timestamp())
}

/// A run non-empty, every code point printable.
fn check_run(run: &str) -> Result<(), Refusal> {
	if run.is_empty() || run.chars().any(|c| u32::from(c) < 32 || c == '\u{7f}') {
		return Err(Refusal::Run);
	}
	Ok(())
}
