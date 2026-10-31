//! A pointer's SSH signature, checked against an allowed signers file as `ssh-keygen -Y` did.
//! Written by the pointer lane.
#![allow(unused_variables)]

/// The namespace a pointer is signed in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Namespace {
	/// `system-pointer`, signed by `ci` alone.
	System,
	/// `driver-pointer`, signed by `ci` or `mac`.
	Driver,
}

/// Whether `signature` signs `message` in `namespace` by a principal the allowed signers file
/// lists for that namespace, `ci` in either and `mac` in `driver-pointer` alone.
pub fn verify(signers: &str, namespace: Namespace, message: &[u8], signature: &[u8]) -> bool {
	todo!()
}
