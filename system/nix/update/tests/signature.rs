//! A pointer's signature verifies for the namespace and the principal the shell allowed.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use machine_update::signature::{Namespace, verify};

fn sample(path: &str) -> Vec<u8> {
	std::fs::read(format!("{}/tests/samples/{path}", env!("CARGO_MANIFEST_DIR"))).unwrap()
}

/// The pointer as it was signed, compact with a newline, the checked-in file being indented since.
fn signed(path: &str) -> Vec<u8> {
	let mut compact = Vec::new();
	let mut quoted = false;
	let mut escaped = false;
	for byte in sample(path) {
		if quoted {
			compact.push(byte);
			match (escaped, byte) {
				(true, _) => escaped = false,
				(false, b'\\') => escaped = true,
				(false, b'"') => quoted = false,
				(false, _) => {}
			}
		} else if !byte.is_ascii_whitespace() {
			quoted = byte == b'"';
			compact.push(byte);
		}
	}
	compact.push(b'\n');
	compact
}

fn text(path: &str) -> String {
	String::from_utf8(sample(path)).unwrap()
}

#[test]
fn the_system_signature_verifies_for_the_system_namespace_alone() {
	let signers = text("signers/system");
	let pointer = signed("pointers/system.json");
	assert!(verify(&signers, Namespace::System, &pointer, &sample("pointers/system.json.sig")));
	assert!(!verify(
		&signers,
		Namespace::System,
		&pointer,
		&sample("pointers/system.json.driver-namespace.sig")
	));
	assert!(!verify(&signers, Namespace::System, &pointer, &sample("pointers/system.json.mac.sig")));
}

#[test]
fn the_driver_signatures_verify_for_ci_and_mac_in_the_driver_namespace_alone() {
	let signers = text("signers/driver");
	let pointer = signed("pointers/driver.json");
	assert!(verify(&signers, Namespace::Driver, &pointer, &sample("pointers/driver.json.sig")));
	assert!(verify(&signers, Namespace::Driver, &pointer, &sample("pointers/driver.json.mac.sig")));
	assert!(!verify(
		&signers,
		Namespace::Driver,
		&pointer,
		&sample("pointers/driver.json.system-namespace.sig")
	));
}

#[test]
fn mac_never_signs_a_system_pointer_even_where_its_line_allows_the_namespace() {
	let ci = text("keys/ci.pub");
	let mac = text("keys/mac.pub");
	let signers = format!(
		"ci namespaces=\"system-pointer\" {}\nmac namespaces=\"system-pointer,driver-pointer\" {}\n",
		ci.trim(),
		mac.trim()
	);
	let pointer = signed("pointers/system.json");
	assert!(verify(&signers, Namespace::System, &pointer, &sample("pointers/system.json.sig")));
	assert!(!verify(&signers, Namespace::System, &pointer, &sample("pointers/system.json.mac.sig")));
}

#[test]
fn a_line_that_does_not_list_the_namespace_does_not_allow_it() {
	let ci = text("keys/ci.pub");
	let signers = format!("ci namespaces=\"driver-pointer\" {}\n", ci.trim());
	let pointer = signed("pointers/system.json");
	assert!(!verify(&signers, Namespace::System, &pointer, &sample("pointers/system.json.sig")));
}

#[test]
fn another_principal_never_signs() {
	let ci = text("keys/ci.pub");
	let signers = format!("other namespaces=\"system-pointer\" {}\n", ci.trim());
	let pointer = signed("pointers/system.json");
	assert!(!verify(&signers, Namespace::System, &pointer, &sample("pointers/system.json.sig")));
}

#[test]
fn a_changed_pointer_or_a_broken_signature_or_no_signers_does_not_verify() {
	let signers = text("signers/system");
	let signature = sample("pointers/system.json.sig");
	let mut pointer = signed("pointers/system.json");
	assert!(!verify(&signers, Namespace::System, b"{}", &signature));
	assert!(!verify(&signers, Namespace::System, &pointer, b"-----BEGIN SSH SIGNATURE-----"));
	assert!(!verify("", Namespace::System, &pointer, &signature));
	pointer.push(b'\n');
	assert!(!verify(&signers, Namespace::System, &pointer, &signature));
}
