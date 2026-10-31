//! The Nix daemon through harmonia's client, a closure taken from the bucket into
//! `AddToStoreNar` and from upstream by `EnsurePath`, RFC cbtjl. Written by the store lane.

use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use std::path::Path;
use std::pin::Pin;

use async_compression::tokio::bufread::ZstdDecoder;
use harmonia_protocol::types::ClientOptions;
use harmonia_protocol::valid_path_info::ValidPathInfo;
use harmonia_store_nar_info::{NarInfo, parse_narinfo_txt};
use harmonia_store_path::{StoreDir, StorePath};
use harmonia_store_path_info::fingerprint_path;
use harmonia_store_remote::{DaemonClient, DaemonClientBuilder, DaemonStore};
use harmonia_utils_signature::PublicKey;
use tokio::io::{AsyncBufRead, BufReader};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

use crate::effects::{Bucket, Store, StoreError};

/// A connection to the daemon, holding the bucket a closure is read from and the keys its
/// narinfos must be signed by.
pub struct Daemon<B> {
	client: DaemonClient<OwnedReadHalf, OwnedWriteHalf>,
	bucket: B,
	trusted: Vec<PublicKey>,
}

impl<B: Bucket> Daemon<B> {
	/// Connects to the daemon's socket, `trusted` the configuration's space separated keys.
	pub async fn connect(socket: &Path, bucket: B, trusted: &str) -> Result<Self, StoreError> {
		let trusted = trusted
			.split_whitespace()
			.map(|key| {
				key.parse::<PublicKey>().map_err(|_| failed(format!("trusted key {key} malformed")))
			})
			.collect::<Result<Vec<_>, _>>()?;
		let mut client = DaemonClientBuilder::new()
			.connect_unix(socket)
			.await
			.map_err(|error| failed_with(format!("daemon at {}", socket.display()), error))?;
		// The shell's `max-jobs 0`, so the daemon substitutes and never builds.
		let mut options = ClientOptions::default();
		options.max_build_jobs = 0;
		client.set_options(&options).await.map_err(|error| failed_with("SetOptions", error))?;
		Ok(Self { client, bucket, trusted })
	}
}

impl<B: Bucket> Store for Daemon<B> {
	async fn realise(&mut self, system: &StorePath) -> Result<(), StoreError> {
		let mut missing = self.walk(system).await?;
		for path in topological(&missing) {
			match missing.remove(&path) {
				Some(Source::Bucket(info)) => self.add(*info).await?,
				Some(Source::Upstream) => self
					.client
					.ensure_path(&path)
					.await
					.map_err(|error| failed_with(format!("EnsurePath {}", full(&path)), error))?,
				None => {}
			}
		}
		Ok(())
	}
}

/// Where a path the store lacks comes from.
enum Source {
	/// The bucket, its narinfo checked.
	Bucket(Box<NarInfo>),
	/// The daemon's own substituters, the bucket holding no narinfo for it.
	Upstream,
}

impl<B: Bucket> Daemon<B> {
	/// Each path of the closure the store lacks, a temporary root taken on each before it is looked
	/// at, the system first, and every narinfo read and checked before anything is added.
	async fn walk(&mut self, system: &StorePath) -> Result<HashMap<StorePath, Source>, StoreError> {
		let mut missing = HashMap::new();
		let mut seen = HashSet::from([system.clone()]);
		let mut queue = VecDeque::from([system.clone()]);
		while let Some(path) = queue.pop_front() {
			self
				.client
				.add_temp_root(&path)
				.await
				.map_err(|error| failed_with(format!("AddTempRoot {}", full(&path)), error))?;
			let valid = self
				.client
				.is_valid_path(&path)
				.await
				.map_err(|error| failed_with(format!("IsValidPath {}", full(&path)), error))?;
			if valid {
				continue;
			}
			let source = match self.narinfo(&path).await? {
				Some(info) => {
					for reference in &info.info.info.references {
						if seen.insert(reference.clone()) {
							queue.push_back(reference.clone());
						}
					}
					Source::Bucket(Box::new(info))
				}
				None => Source::Upstream,
			};
			missing.insert(path, source);
		}
		Ok(missing)
	}

	/// A path's narinfo from the bucket, `None` where it has none, refused unless it names the path
	/// and a trusted key signed it.
	async fn narinfo(&self, path: &StorePath) -> Result<Option<NarInfo>, StoreError> {
		let key = format!("{}.narinfo", path.hash());
		let text = match self.bucket.get(&key).await {
			Ok(Some(text)) => text,
			Ok(None) => return Ok(None),
			Err(error) => return Err(failed_with(format!("narinfo of {}", full(path)), error)),
		};
		let text = String::from_utf8(text)
			.map_err(|_| failed(format!("narinfo of {} is not text", full(path))))?;
		let info = parse_narinfo_txt(&StoreDir::default(), &text)
			.map_err(|error| failed_with(format!("narinfo of {}", full(path)), error))?;
		if info.path != *path {
			return Err(failed(format!("narinfo of {} names {}", full(path), full(&info.path))));
		}
		let unkeyed = &info.info.info;
		let fingerprint = fingerprint_path(
			&unkeyed.store_dir,
			&info.path,
			&unkeyed.nar_hash,
			unkeyed.nar_size,
			&unkeyed.references,
		);
		let signed = unkeyed.signatures.iter().any(|signature| {
			self
				.trusted
				.iter()
				.any(|key| key.name() == signature.name() && key.verify(&fingerprint, signature))
		});
		if !signed {
			return Err(failed(format!("narinfo of {} is signed by no trusted key", full(path))));
		}
		Ok(Some(info))
	}

	/// Streams a path's NAR from the bucket into the daemon, which checks its hash and signature
	/// again.
	async fn add(&mut self, info: NarInfo) -> Result<(), StoreError> {
		let path = full(&info.path);
		let url = info.info.url.as_deref().unwrap_or_default();
		if url.is_empty()
			|| url.starts_with('/')
			|| url.contains("://")
			|| url.split('/').any(|part| part == "..")
		{
			return Err(failed(format!("narinfo of {path} names a NAR outside the bucket")));
		}
		let zstd = match info.info.compression.as_deref() {
			None | Some("none") => false,
			Some("zstd") => true,
			Some(other) => return Err(failed(format!("NAR of {path} has compression {other}"))),
		};
		let object = match self.bucket.open(url).await {
			Ok(Some(object)) => object,
			Ok(None) => return Err(failed(format!("NAR of {path} missing from the bucket"))),
			Err(error) => return Err(failed_with(format!("NAR of {path}"), error)),
		};
		let source: Pin<Box<dyn AsyncBufRead + Send>> = if zstd {
			Box::pin(BufReader::new(ZstdDecoder::new(BufReader::new(object))))
		} else {
			Box::pin(BufReader::new(object))
		};
		let valid = ValidPathInfo { path: info.path, info: info.info.info };
		self
			.client
			.add_to_store_nar(&valid, source, false, false)
			.await
			.map_err(|error| failed_with(format!("AddToStoreNar {path}"), error))
	}
}

/// The missing paths in an order where each comes after every path it references.
fn topological(missing: &HashMap<StorePath, Source>) -> Vec<StorePath> {
	let references = |path: &StorePath| -> Vec<StorePath> {
		match missing.get(path) {
			Some(Source::Bucket(info)) => info
				.info
				.info
				.references
				.iter()
				.filter(|reference| *reference != path && missing.contains_key(*reference))
				.cloned()
				.collect(),
			Some(Source::Upstream) | None => Vec::new(),
		}
	};
	let mut roots: Vec<&StorePath> = missing.keys().collect();
	roots.sort();
	let mut order = Vec::new();
	let mut placed = HashSet::new();
	for root in roots {
		if !placed.insert(root.clone()) {
			continue;
		}
		let mut stack = vec![(root.clone(), 0usize)];
		while let Some((path, next)) = stack.last().cloned() {
			let child = references(&path).get(next).cloned();
			if let Some(top) = stack.last_mut() {
				top.1 += 1;
			}
			match child {
				Some(child) => {
					if placed.insert(child.clone()) {
						stack.push((child, 0));
					}
				}
				None => {
					stack.pop();
					order.push(path);
				}
			}
		}
	}
	order
}

/// A store path written whole.
fn full(path: &StorePath) -> String {
	StoreDir::default().display(path).to_string()
}

/// An error of one line.
fn failed(line: String) -> StoreError {
	StoreError { lines: vec![line] }
}

/// An error naming what failed, then the cause's own lines.
fn failed_with(what: impl fmt::Display, cause: impl fmt::Display) -> StoreError {
	let text = format!("{what}: {cause}");
	StoreError { lines: text.lines().map(str::to_owned).collect() }
}

#[cfg(test)]
mod tests {
	use super::*;

	fn info(path: &str, references: &[&str]) -> (StorePath, Source) {
		let mut text = format!(
			"StorePath: /nix/store/{path}\nURL: nar/x.nar\nNarHash: sha256:10f6lxb7j9cii6ffzl5agc6hla2r38myzn9vqv72ry3iyblv0ka9\nNarSize: 1\n"
		);
		text.push_str(&format!("References: {}\n", references.join(" ")));
		let info = parse_narinfo_txt(&StoreDir::default(), &text).unwrap();
		(info.path.clone(), Source::Bucket(Box::new(info)))
	}

	#[test]
	fn references_come_before_referrers() {
		let leaf = "29kfahjgyi2rkxbz2f4zzspqf1by85za-leaf";
		let middle = "hzm4hmqjl2qmpm3qm1dciwj34rpfml14-middle";
		let system = "3aawm31cggmw6qv0kkhha3ca29sr92f7-system";
		let upstream: StorePath = "00000000000000000000000000000000-upstream".parse().unwrap();
		let missing: HashMap<_, _> = [
			info(system, &[leaf, middle, system, "11111111111111111111111111111111-valid"]),
			info(middle, &[leaf, "00000000000000000000000000000000-upstream", middle]),
			info(leaf, &[]),
			(upstream, Source::Upstream),
		]
		.into_iter()
		.collect();
		let order: Vec<String> = topological(&missing).iter().map(ToString::to_string).collect();
		let at = |name: &str| order.iter().position(|p| p == name).unwrap();
		assert_eq!(order.len(), 4);
		assert!(at(leaf) < at(middle));
		assert!(at("00000000000000000000000000000000-upstream") < at(middle));
		assert!(at(middle) < at(system));
	}

	#[test]
	fn a_cause_spreads_over_lines() {
		let error = failed_with("AddToStoreNar /nix/store/x", "first\nsecond");
		assert_eq!(error.lines, ["AddToStoreNar /nix/store/x: first", "second"]);
	}
}
