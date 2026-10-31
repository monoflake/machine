//! A pointer's signature verifies for the namespace and the principal the shell allowed.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use machine_update::signature::{Namespace, verify};

fn sample(path: &str) -> Vec<u8> {
	std::fs::read(format!("{}/tests/samples/{path}", env!("CARGO_MANIFEST_DIR"))).unwrap()
}

/// The pointer's bytes as they were signed, kept without an extension so no formatter touches them.
fn signed(path: &str) -> Vec<u8> {
	sample(path)
}

fn text(path: &str) -> String {
	String::from_utf8(sample(path)).unwrap()
}

#[test]
fn the_system_signature_verifies_for_the_system_namespace_alone() {
	let signers = text("signers/system");
	let pointer = signed("pointers/system");
	assert!(verify(&signers, Namespace::System, &pointer, &sample("pointers/system.sig")));
	assert!(!verify(
		&signers,
		Namespace::System,
		&pointer,
		&sample("pointers/system.driver-namespace.sig")
	));
	assert!(!verify(&signers, Namespace::System, &pointer, &sample("pointers/system.mac.sig")));
}

#[test]
fn the_driver_signatures_verify_for_ci_and_mac_in_the_driver_namespace_alone() {
	let signers = text("signers/driver");
	let pointer = signed("pointers/driver");
	assert!(verify(&signers, Namespace::Driver, &pointer, &sample("pointers/driver.sig")));
	assert!(verify(&signers, Namespace::Driver, &pointer, &sample("pointers/driver.mac.sig")));
	assert!(!verify(
		&signers,
		Namespace::Driver,
		&pointer,
		&sample("pointers/driver.system-namespace.sig")
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
	let pointer = signed("pointers/system");
	assert!(verify(&signers, Namespace::System, &pointer, &sample("pointers/system.sig")));
	assert!(!verify(&signers, Namespace::System, &pointer, &sample("pointers/system.mac.sig")));
}

#[test]
fn a_line_that_does_not_list_the_namespace_does_not_allow_it() {
	let ci = text("keys/ci.pub");
	let signers = format!("ci namespaces=\"driver-pointer\" {}\n", ci.trim());
	let pointer = signed("pointers/system");
	assert!(!verify(&signers, Namespace::System, &pointer, &sample("pointers/system.sig")));
}

#[test]
fn another_principal_never_signs() {
	let ci = text("keys/ci.pub");
	let signers = format!("other namespaces=\"system-pointer\" {}\n", ci.trim());
	let pointer = signed("pointers/system");
	assert!(!verify(&signers, Namespace::System, &pointer, &sample("pointers/system.sig")));
}

#[test]
fn a_changed_pointer_or_a_broken_signature_or_no_signers_does_not_verify() {
	let signers = text("signers/system");
	let signature = sample("pointers/system.sig");
	let mut pointer = signed("pointers/system");
	assert!(!verify(&signers, Namespace::System, b"{}", &signature));
	assert!(!verify(&signers, Namespace::System, &pointer, b"-----BEGIN SSH SIGNATURE-----"));
	assert!(!verify("", Namespace::System, &pointer, &signature));
	pointer.push(b'\n');
	assert!(!verify(&signers, Namespace::System, &pointer, &signature));
}

#[test]
fn restricted_or_pattern_options_fail_closed() {
	let ci = text("keys/ci.pub");
	let pointer = signed("pointers/system");
	let signature = sample("pointers/system.sig");
	for options in [
		"namespaces=\"driver-pointer\",valid-before=\"20990101\"",
		"namespaces=\"driver-pointer\",cert-authority",
		"namespaces=\"system-pointer\",valid-after=\"20000101\"",
		"cert-authority,namespaces=\"system-pointer\"",
		"namespaces=\"!system-pointer,*\"",
		"namespaces=\"system-pointer,?\"",
		"namespaces=\"system-pointer,*\"",
		"namespaces=\"system-pointer",
	] {
		let signers = format!("ci {options} {}", ci.trim());
		assert!(
			!verify(&signers, Namespace::System, &pointer, &signature),
			"unsupported or malformed options must fail closed {options}"
		);
	}
	let signers = format!("ci namespaces=\"driver-pointer,system-pointer\" {}", ci.trim());
	assert!(verify(&signers, Namespace::System, &pointer, &signature));
}
