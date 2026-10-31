//! The pointer protocols give the reason the shell gave for every sample.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use machine_update::output::Refusal;
use machine_update::pointer::{driver, system};
use serde_json::{Value, json};

/// 2026-10-29T14:00:00Z, the clock the samples were produced with.
const NOW: i64 = 1_793_282_400;

fn samples() -> Vec<Value> {
	let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/samples/refusals.json");
	serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

#[test]
fn every_sample_gets_the_reason_the_shell_gave() {
	let samples = samples();
	assert_eq!(samples.len(), 70);
	for sample in &samples {
		let bytes = serde_json::to_vec(&sample["pointer"]).unwrap();
		let reason = match sample["protocol"].as_str().unwrap() {
			"system" => system(&bytes, "c1", NOW).err(),
			"driver" => driver(&bytes, "c1", NOW, sample["builds"].as_bool().unwrap()).err(),
			other => panic!("unknown protocol {other}"),
		};
		let expected = sample["reason"].as_str();
		assert_eq!(reason.map(|r| r.to_string()).as_deref(), expected, "{sample}");
	}
}

fn driver_pointer(url: &str, sha256: &str) -> Vec<u8> {
	let archive = json!({"url": url, "sha256": sha256});
	let pointer = json!({
		"machine": "c1", "version": "1.0", "at": "2026-10-29T13:00:00Z", "run": "1",
		"archives": {"x86_64-linux": archive, "aarch64-linux": archive},
	});
	serde_json::to_vec(&pointer).unwrap()
}

#[test]
fn a_system_pointer_keeps_its_fields() {
	let bytes = br#"{"at":"2026-10-29T13:00:00Z","machine":"c1","path":"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system","run":"7"}"#;
	let pointer = system(bytes, "c1", NOW).unwrap();
	assert_eq!(pointer.path, "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system");
	assert_eq!((pointer.at.as_str(), pointer.run.as_str()), ("2026-10-29T13:00:00Z", "7"));
}

#[test]
fn text_that_is_no_json_is_malformed_fields() {
	assert_eq!(system(b"not json", "c1", NOW), Err(Refusal::Fields));
	assert_eq!(driver(b"", "c1", NOW, true), Err(Refusal::DriverFields));
}

#[test]
fn an_archive_is_chosen_by_architecture_with_its_hash_lowercased() {
	let upper = "0EB3E36BFB24DCD9BB1D1BECE1531216B59539A8FDE17EE80224AF0653C92AA3";
	let pointer =
		driver(&driver_pointer("https://example.invalid/a", upper), "c1", NOW, false).unwrap();
	let archive = pointer.archive("x86_64-linux").unwrap();
	assert_eq!(archive.sha256, upper.to_ascii_lowercase());
	assert_eq!(archive.url, "https://example.invalid/a");
	assert_eq!(pointer.archive("aarch64-linux"), Some(&pointer.aarch64));
	assert_eq!(pointer.archive("riscv64-linux"), None);
}

#[test]
fn a_bucket_build_is_named_by_the_hash_as_written() {
	let upper = "0EB3E36BFB24DCD9BB1D1BECE1531216B59539A8FDE17EE80224AF0653C92AA3";
	let lower = upper.to_ascii_lowercase();
	let written = driver_pointer(&format!("build/driver/{upper}.tar.gz"), upper);
	assert!(driver(&written, "c1", NOW, true).is_ok());
	let other = driver_pointer(&format!("build/driver/{lower}.tar.gz"), upper);
	assert_eq!(driver(&other, "c1", NOW, true), Err(Refusal::DriverFields));
}

#[test]
fn a_hash_with_a_trailing_newline_is_refused() {
	let sha = format!("{}\n", "a".repeat(64));
	assert_eq!(
		driver(&driver_pointer("https://example.invalid/a", &sha), "c1", NOW, true),
		Err(Refusal::DriverFields)
	);
}

#[test]
fn unicode_whitespace_in_archive_urls_is_refused() {
	for space in ['\u{a0}', '\u{2028}'] {
		let url = format!("https://example.invalid/a{space}b");
		assert_eq!(
			driver(&driver_pointer(&url, &"a".repeat(64)), "c1", NOW, true),
			Err(Refusal::DriverFields),
			"jq refused Unicode spaces too"
		);
	}
}
