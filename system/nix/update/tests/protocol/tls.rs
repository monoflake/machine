//! The provider the features choose is installed, and an HTTPS client builds on it.

#[test]
fn client_builds_on_the_chosen_provider() {
	machine_update::tls::install();
	machine_update::tls::install();
	let expected = if cfg!(feature = "aws-lc-rs") { "aws-lc-rs" } else { "ring" };
	assert_eq!(machine_update::tls::provider(), expected);
	reqwest::Client::builder().build().expect("a client builds on the installed provider");
}
