//! HTTPS's crypto provider, installed for the process before any client is built, aws-lc-rs by
//! default and ring behind its feature, RFC cbtjl.

#[cfg(not(any(feature = "aws-lc-rs", feature = "ring")))]
compile_error!("machine-update needs the aws-lc-rs or the ring feature");

/// Installs the provider the features choose, aws-lc-rs where both are on, once per process.
pub fn install() {
	#[cfg(feature = "aws-lc-rs")]
	let provider = rustls::crypto::aws_lc_rs::default_provider();
	#[cfg(all(feature = "ring", not(feature = "aws-lc-rs")))]
	let provider = rustls::crypto::ring::default_provider();
	// A second call finds one installed already, which is the same provider.
	let _ = provider.install_default();
}

/// The provider's name, `aws-lc-rs` or `ring`.
pub fn provider() -> &'static str {
	if cfg!(feature = "aws-lc-rs") { "aws-lc-rs" } else { "ring" }
}
