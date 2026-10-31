//! The bucket over S3 with the systems credentials, or a directory for a test, and a driver archive
//! over HTTPS, as `fetch.sh` and `driver.sh` read them. Written by the store lane.
#![allow(unused_variables)]

use std::path::PathBuf;

use crate::effects::{Bucket, BucketError, Download, Object};
use crate::output::Refusal;

/// The `[systems]` profile's key pair.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Credentials {
	/// `aws_access_key_id`, letters and digits.
	pub key: String,
	/// `aws_secret_access_key`, base64's alphabet.
	pub secret: String,
}

/// Reads the `[systems]` profile from a shared credentials file, each key once, as `credential`
/// read it, refusing anything else as malformed.
pub fn credentials(text: &str) -> Result<Credentials, Refusal> {
	todo!()
}

/// The bucket a configuration names.
#[derive(Debug)]
pub enum Remote {
	/// A bucket over S3, path style, region `auto`.
	S3 {
		/// The bucket's name.
		bucket: String,
		/// The endpoint's host, with its port where it has one.
		host: String,
		/// The key pair requests are signed with.
		credentials: Credentials,
	},
	/// A bucket on disk, `file:///<directory>`.
	Directory(PathBuf),
}

impl Remote {
	/// The bucket for a configuration's name and endpoint, refusing a malformed name or endpoint.
	pub fn new(bucket: &str, endpoint: &str, credentials: Credentials) -> Result<Self, Refusal> {
		todo!()
	}
}

impl Bucket for Remote {
	async fn get(&self, key: &str) -> Result<Option<Vec<u8>>, BucketError> {
		todo!()
	}

	async fn open(&self, key: &str) -> Result<Option<Object>, BucketError> {
		todo!()
	}
}

/// HTTPS downloads, a redirect followed to HTTPS alone.
#[derive(Debug, Default)]
pub struct Https;

impl Download for Https {
	async fn download(&self, url: &str) -> Result<Vec<u8>, BucketError> {
		todo!()
	}
}
