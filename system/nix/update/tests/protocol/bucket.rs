//! The `[systems]` profile read as `fetch.sh`'s awk read it, and a bucket's name and endpoint
//! checked as its patterns checked them.

use machine_update::bucket::{Credentials, Remote, credentials};
use machine_update::output::Refusal;

const KEY: &str = "AKIA0123abcd";
const SECRET: &str = "wJal/rXUt+nFEMI=";

fn pair() -> Credentials {
	Credentials { key: KEY.into(), secret: SECRET.into() }
}

#[test]
fn reads_the_systems_profile_alone() {
	let text = format!(
		"[other]\naws_access_key_id = ignored\n[systems]\naws_access_key_id = {KEY}\naws_secret_access_key = {SECRET}\n"
	);
	assert_eq!(credentials(&text), Ok(pair()));
}

#[test]
fn trims_blanks_and_carriage_returns() {
	let text = format!(
		"\t[systems]  \r\n  aws_access_key_id\t=\t {KEY} \r\n# aws_access_key_id = commented\r\n; aws_secret_access_key = commented\r\naws_secret_access_key={SECRET}\r\n"
	);
	assert_eq!(credentials(&text), Ok(pair()));
}

#[test]
fn a_later_systems_section_counts_too() {
	let text = format!(
		"[systems]\naws_access_key_id = {KEY}\n[other]\naws_secret_access_key = other\n[systems]\naws_secret_access_key = {SECRET}\n"
	);
	assert_eq!(credentials(&text), Ok(pair()));
}

#[test]
fn refuses_a_missing_or_repeated_key() {
	let cases = [
		format!("[systems]\naws_access_key_id = {KEY}\n"),
		format!("[systems]\naws_secret_access_key = {SECRET}\n"),
		format!("aws_access_key_id = {KEY}\naws_secret_access_key = {SECRET}\n"),
		format!(
			"[systems]\naws_access_key_id = {KEY}\naws_access_key_id = {KEY}\naws_secret_access_key = {SECRET}\n"
		),
		format!("[ systems ]\naws_access_key_id = {KEY}\naws_secret_access_key = {SECRET}\n"),
		format!("[systems] x\naws_access_key_id = {KEY}\naws_secret_access_key = {SECRET}\n"),
		String::new(),
	];
	for text in cases {
		assert_eq!(credentials(&text), Err(Refusal::Credentials), "{text:?}");
	}
}

#[test]
fn refuses_a_value_outside_its_alphabet() {
	let cases = [
		("AKIA-0123", SECRET),
		("", SECRET),
		(KEY, ""),
		(KEY, "wJal rXUt"),
		(KEY, "wJal_rXUt"),
		("AKIA0123\u{e9}", SECRET),
		(KEY, "x\ry"),
	];
	for (key, secret) in cases {
		let text = format!("[systems]\naws_access_key_id = {key}\naws_secret_access_key = {secret}\n");
		assert_eq!(credentials(&text), Err(Refusal::Credentials), "{text:?}");
	}
}

#[test]
fn a_directory_bucket_needs_no_endpoint() {
	match Remote::new("file:///var/lib/bucket", "not an endpoint", pair()) {
		Ok(Remote::Directory(path)) => assert_eq!(path.to_str(), Some("/var/lib/bucket")),
		other => panic!("{other:?}"),
	}
}

#[test]
fn an_s3_bucket_takes_its_host_from_the_endpoint() {
	for (endpoint, host) in [
		("https://abc.r2.cloudflarestorage.com", "abc.r2.cloudflarestorage.com"),
		("https://abc.r2.cloudflarestorage.com/", "abc.r2.cloudflarestorage.com"),
		("https://localhost:9000\n", "localhost:9000"),
	] {
		match Remote::new("systems.v1-a", endpoint, pair()) {
			Ok(Remote::S3 { bucket, host: taken, credentials }) => {
				assert_eq!(bucket, "systems.v1-a");
				assert_eq!(taken, host);
				assert_eq!(credentials, pair());
			}
			other => panic!("{endpoint}: {other:?}"),
		}
	}
}

#[test]
fn refuses_a_malformed_bucket_before_the_endpoint() {
	for bucket in
		["", "Systems", "-systems", ".systems", "sys_tems", "file://relative", "s3://systems"]
	{
		let refusal = Remote::new(bucket, "not an endpoint", pair()).map(|_| ());
		assert_eq!(refusal, Err(Refusal::Bucket), "{bucket:?}");
	}
}

#[test]
fn refuses_a_malformed_endpoint() {
	for endpoint in [
		"",
		"http://host",
		"https://",
		"https:///",
		"https://host//",
		"https://host/path",
		"https://host:",
		"https://host:port",
		"https://user@host",
		"https://host_name",
		"https://host?query",
	] {
		let refusal = Remote::new("systems", endpoint, pair()).map(|_| ());
		assert_eq!(refusal, Err(Refusal::EndpointMalformed), "{endpoint:?}");
	}
}
