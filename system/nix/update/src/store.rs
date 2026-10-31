//! The Nix daemon through harmonia's client, a closure taken from the bucket into
//! `AddToStoreNar` and from upstream by `EnsurePath`, RFC cbtjl. Written by the store lane.
#![allow(unused_variables, dead_code)]

use std::path::Path;

use harmonia_store_path::StorePath;

use crate::effects::{Bucket, Store, StoreError};

/// A connection to the daemon, holding the bucket a closure is read from and the keys its
/// narinfos must be signed by.
pub struct Daemon<B> {
	bucket: B,
	trusted: Vec<String>,
}

impl<B: Bucket> Daemon<B> {
	/// Connects to the daemon's socket, `trusted` the configuration's space separated keys.
	pub async fn connect(socket: &Path, bucket: B, trusted: &str) -> Result<Self, StoreError> {
		todo!()
	}
}

impl<B: Bucket> Store for Daemon<B> {
	async fn realise(&mut self, system: &StorePath) -> Result<(), StoreError> {
		todo!()
	}
}
