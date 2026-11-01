//! This crate's lint table stays the workspace's but for `unsafe_code`, RFC cbtjl item 10.
#![allow(clippy::expect_used)]

use std::path::Path;

/// The table's lines under a header, up to its blank line, without `unsafe_code`.
fn table(manifest: &str, header: &str) -> Vec<String> {
	manifest
		.lines()
		.skip_while(|line| *line != header)
		.skip(1)
		.take_while(|line| !line.is_empty())
		.filter(|line| !line.starts_with("unsafe_code"))
		.map(str::to_owned)
		.collect()
}

#[test]
fn lints_are_the_workspaces_but_for_unsafe_code() {
	let own = Path::new(env!("CARGO_MANIFEST_DIR"));
	let workspace = own.join("../../../../Cargo.toml");
	let workspace = std::fs::read_to_string(workspace).expect("the workspace's manifest");
	let crate_ = std::fs::read_to_string(own.join("Cargo.toml")).expect("this crate's manifest");
	for kind in ["rust", "clippy"] {
		let wanted = table(&workspace, &format!("[workspace.lints.{kind}]"));
		assert!(!wanted.is_empty(), "the workspace has no {kind} lints");
		assert_eq!(table(&crate_, &format!("[lints.{kind}]")), wanted);
	}
}
