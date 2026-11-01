//! The last install that went back, written where cloud's `pointer --driver` reads it over ssh, so
//! a pointer tried again at each window and rolled back each time is seen, RFC okz12.

use std::io;
use std::path::Path;

use serde_json::{Value, json};
use time::OffsetDateTime;
use time::macros::format_description;

use crate::state;

/// The most of a reason kept, in characters.
const WHY: usize = 400;

/// An install that went back.
#[derive(Debug, Clone, Copy)]
pub struct Attempt<'a> {
	/// The version tried.
	pub version: &'a str,
	/// The run its pointer names.
	pub run: &'a str,
	/// When its pointer was signed.
	pub pointer_at: &'a str,
	/// `restart` or `check`.
	pub stage: &'a str,
	/// Why, masked.
	pub why: &'a str,
	/// When, in seconds since the epoch.
	pub at: i64,
}

fn utc(at: i64) -> String {
	let written = format_description!("[year]-[month]-[day]T[hour]:[minute]:[second]Z");
	OffsetDateTime::from_unix_timestamp(at)
		.ok()
		.and_then(|at| at.format(written).ok())
		.unwrap_or_else(|| at.to_string())
}

/// Written whole, `times` counting the attempts at one pointer.
pub fn write(file: &Path, attempt: &Attempt<'_>) -> io::Result<()> {
	let held = state::read(file)
		.ok()
		.flatten()
		.and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
		.filter(|held| {
			let field = |name| held.get(name).and_then(Value::as_str);
			field("run") == Some(attempt.run) && field("pointerAt") == Some(attempt.pointer_at)
		});
	let times = held.and_then(|held| held.get("times")?.as_u64()).unwrap_or(0).saturating_add(1);
	let why: String = attempt.why.chars().take(WHY).collect();
	let written = json!({
		"version": attempt.version,
		"run": attempt.run,
		"pointerAt": attempt.pointer_at,
		"stage": attempt.stage,
		"why": why,
		"at": utc(attempt.at),
		"times": times,
	});
	state::record(file, written.to_string().as_bytes())
}

/// Gone, as a pointer was taken; none there being no failure.
pub fn clear(file: &Path) {
	let _ = std::fs::remove_file(file);
}
