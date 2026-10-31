//! A closure taken into a temporary store under a trusted daemon, from the sample bucket in
//! references' order or the daemon's upstream, refused where a narinfo is not the one signed.

#![cfg(test)]

mod daemon;

use std::fs;
use std::future::Future;
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use daemon::{LEAF, MIDDLE, SYSTEM, TestDaemon, bucket, path, trusted};
use harmonia_protocol::ProtocolVersion;
use harmonia_protocol::daemon_wire::logger::STDERR_LAST;
use harmonia_protocol::daemon_wire::types::Operation;
use harmonia_protocol::daemon_wire::{CLIENT_MAGIC, SERVER_MAGIC};
use harmonia_protocol::de::{NixRead, NixReader};
use harmonia_protocol::ser::{NixWrite, NixWriter};
use harmonia_protocol::types::{ClientOptions, TrustLevel};
use machine_update::bucket::Remote;
use machine_update::effects::{Bucket, BucketError, Object, Store, StoreError};
use machine_update::store::Daemon;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixListener;

#[tokio::test]
async fn connection_disallows_build_jobs_and_keeps_substitution_enabled() {
	within_a_minute(async {
		let (_directory, root) = daemon::directory();
		let socket = root.join("socket");
		let listener = UnixListener::bind(&socket).unwrap();
		let server = tokio::spawn(async move {
			let (stream, _) = listener.accept().await.unwrap();
			let (read, write) = stream.into_split();
			let mut reader = NixReader::new(read);
			let mut writer = NixWriter::new(write);
			assert_eq!(reader.read_number().await.unwrap(), CLIENT_MAGIC);
			let version = ProtocolVersion::from_parts(1, 37);
			writer.write_number(SERVER_MAGIC).await.unwrap();
			writer.write_value(&version).await.unwrap();
			writer.flush().await.unwrap();
			assert_eq!(reader.read_value::<ProtocolVersion>().await.unwrap(), version);
			reader.set_version(version);
			writer.set_version(version);
			assert!(!reader.read_value::<bool>().await.unwrap());
			assert!(!reader.read_value::<bool>().await.unwrap());
			writer.write_value("test daemon").await.unwrap();
			writer.write_value(&Some(TrustLevel::Trusted)).await.unwrap();
			writer.write_number(STDERR_LAST).await.unwrap();
			writer.flush().await.unwrap();
			assert_eq!(reader.read_value::<Operation>().await.unwrap(), Operation::SetOptions);
			let options = reader.read_value::<ClientOptions>().await.unwrap();
			writer.write_number(STDERR_LAST).await.unwrap();
			writer.flush().await.unwrap();
			options
		});
		let _store =
			Daemon::connect(&socket, Remote::Directory(root.clone()), &trusted()).await.unwrap();
		let options = server.await.unwrap();
		assert_eq!(options.max_build_jobs, 0, "realization must never start a build job");
		assert!(options.use_substitutes, "missing paths must come from substitutes");
		// The connection leaves builders at the daemon's setting rather than overriding them.
		assert!(!options.other_settings.contains_key("builders"));
	})
	.await;
}

/// Fails a test that runs past a minute rather than letting it hang.
async fn within_a_minute<F: Future<Output = ()>>(test: F) {
	tokio::time::timeout(Duration::from_secs(60), test).await.expect("the test ran past a minute");
}

/// A directory bucket recording each key asked for.
struct Recorded {
	remote: Remote,
	keys: Mutex<Vec<String>>,
}

impl Recorded {
	fn new(directory: &Path) -> Self {
		Self { remote: Remote::Directory(directory.to_owned()), keys: Mutex::new(Vec::new()) }
	}

	fn keys(&self) -> Vec<String> {
		self.keys.lock().unwrap().clone()
	}
}

impl Bucket for &Recorded {
	async fn get(&self, key: &str) -> Result<Option<Vec<u8>>, BucketError> {
		self.keys.lock().unwrap().push(key.to_owned());
		self.remote.get(key).await
	}

	async fn open(&self, key: &str) -> Result<Option<Object>, BucketError> {
		self.keys.lock().unwrap().push(key.to_owned());
		self.remote.open(key).await
	}
}

async fn realise(daemon: &TestDaemon, directory: &Path) -> Result<(), StoreError> {
	let mut store =
		Daemon::connect(daemon.socket(), Remote::Directory(directory.to_owned()), &trusted())
			.await
			.unwrap();
	store.realise(&path(SYSTEM)).await
}

async fn holds(daemon: &TestDaemon) -> [bool; 3] {
	[daemon.valid(LEAF).await, daemon.valid(MIDDLE).await, daemon.valid(SYSTEM).await]
}

/// Rewrites one line of a narinfo in a bucket copy.
fn edit(directory: &Path, base: &str, from: &str, to: &str) {
	let hash = base.split('-').next().unwrap();
	let file = directory.join(format!("{hash}.narinfo"));
	let text = fs::read_to_string(&file).unwrap();
	assert!(text.contains(from), "{from} not in {file:?}");
	fs::write(file, text.replacen(from, to, 1)).unwrap();
}

#[tokio::test]
async fn takes_the_closure_from_the_bucket_references_first() {
	within_a_minute(async {
		let daemon = TestDaemon::start(None).await;
		let (_dir, directory) = bucket(&[]);
		assert_eq!(holds(&daemon).await, [false; 3]);
		let result = realise(&daemon, &directory).await;
		assert!(result.is_ok(), "{result:?}\n{}", daemon.log());
		assert_eq!(holds(&daemon).await, [true; 3]);
	})
	.await;
}

#[tokio::test]
async fn takes_a_path_the_bucket_lacks_from_upstream() {
	within_a_minute(async {
		let (_upstream_dir, upstream) = bucket(&[MIDDLE, SYSTEM]);
		let daemon = TestDaemon::start(Some(&upstream)).await;
		let (_dir, directory) = bucket(&[LEAF]);
		let result = realise(&daemon, &directory).await;
		assert!(result.is_ok(), "{result:?}\n{}", daemon.log());
		assert_eq!(holds(&daemon).await, [true; 3]);
	})
	.await;
}

#[tokio::test]
async fn a_path_neither_has_adds_nothing() {
	within_a_minute(async {
		let daemon = TestDaemon::start(None).await;
		let (_dir, directory) = bucket(&[LEAF]);
		let error = realise(&daemon, &directory).await.unwrap_err();
		assert!(error.lines[0].starts_with(&format!("EnsurePath /nix/store/{LEAF}")), "{error:?}");
		assert_eq!(holds(&daemon).await, [false; 3]);
	})
	.await;
}

#[tokio::test]
async fn refuses_a_tampered_signature_adding_nothing() {
	within_a_minute(async {
		let daemon = TestDaemon::start(None).await;
		let (_dir, directory) = bucket(&[]);
		edit(&directory, MIDDLE, "Sig: update-test-1:mEen", "Sig: update-test-1:nEen");
		let error = realise(&daemon, &directory).await.unwrap_err();
		assert_eq!(
			error.lines,
			[format!("narinfo of /nix/store/{MIDDLE} is signed by no trusted key")]
		);
		assert_eq!(holds(&daemon).await, [false; 3]);
	})
	.await;
}

#[tokio::test]
async fn refuses_a_narinfo_naming_another_path() {
	within_a_minute(async {
		let daemon = TestDaemon::start(None).await;
		let (_dir, directory) = bucket(&[]);
		edit(
			&directory,
			SYSTEM,
			&format!("StorePath: /nix/store/{SYSTEM}"),
			&format!("StorePath: /nix/store/{MIDDLE}"),
		);
		let error = realise(&daemon, &directory).await.unwrap_err();
		assert_eq!(error.lines, [format!("narinfo of /nix/store/{SYSTEM} names /nix/store/{MIDDLE}")]);
		assert_eq!(holds(&daemon).await, [false; 3]);
	})
	.await;
}

#[tokio::test]
async fn a_valid_system_reads_nothing() {
	within_a_minute(async {
		let daemon = TestDaemon::start(None).await;
		let (_dir, directory) = bucket(&[]);
		let result = realise(&daemon, &directory).await;
		assert!(result.is_ok(), "{result:?}\n{}", daemon.log());
		let recorded = Recorded::new(&directory);
		let mut store = Daemon::connect(daemon.socket(), &recorded, &trusted()).await.unwrap();
		store.realise(&path(SYSTEM)).await.unwrap();
		assert_eq!(recorded.keys(), Vec::<String>::new());
	})
	.await;
}

#[tokio::test]
async fn reads_only_what_the_store_lacks() {
	within_a_minute(async {
		let daemon = TestDaemon::start(None).await;
		let (_dir, directory) = bucket(&[]);
		let mut store =
			Daemon::connect(daemon.socket(), Remote::Directory(directory.clone()), &trusted())
				.await
				.unwrap();
		store.realise(&path(LEAF)).await.unwrap();
		assert_eq!(holds(&daemon).await, [true, false, false]);
		let recorded = Recorded::new(&directory);
		let mut store = Daemon::connect(daemon.socket(), &recorded, &trusted()).await.unwrap();
		store.realise(&path(SYSTEM)).await.unwrap();
		let hash = |base: &str| base.split('-').next().unwrap().to_owned();
		let keys = recorded.keys();
		assert_eq!(keys.len(), 4, "{keys:?}");
		assert_eq!(keys[0], format!("{}.narinfo", hash(SYSTEM)));
		assert_eq!(keys[1], format!("{}.narinfo", hash(MIDDLE)));
		assert!(keys[2..].iter().all(|key| key.starts_with("nar/")), "{keys:?}");
		assert_eq!(holds(&daemon).await, [true; 3]);
	})
	.await;
}
