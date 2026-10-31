//! A temporary store under its own trusted daemon, stopped and removed when dropped.

#![cfg(test)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use harmonia_store_path::StorePath;
use harmonia_store_remote::{DaemonClientBuilder, DaemonStore};
use tempfile::TempDir;

/// The sample bucket `nix copy` wrote, its three paths leaf, middle and system.
pub fn samples() -> PathBuf {
	Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/samples")
}

/// The key the sample bucket is signed with.
pub fn trusted() -> String {
	fs::read_to_string(samples().join("keys/nix.pub")).unwrap().trim().to_owned()
}

pub const LEAF: &str = "29kfahjgyi2rkxbz2f4zzspqf1by85za-update-sample-leaf";
pub const MIDDLE: &str = "hzm4hmqjl2qmpm3qm1dciwj34rpfml14-update-sample-middle";
pub const SYSTEM: &str = "3aawm31cggmw6qv0kkhha3ca29sr92f7-update-sample-system";

pub fn path(base: &str) -> StorePath {
	base.parse().unwrap()
}

/// A temporary directory with its symlinks resolved, since Nix refuses a store under one.
pub fn directory() -> (TempDir, PathBuf) {
	let dir = tempfile::Builder::new().prefix("mu").tempdir().unwrap();
	let real = dir.path().canonicalize().unwrap();
	(dir, real)
}

/// A copy of the sample bucket, without the paths named.
pub fn bucket(without: &[&str]) -> (TempDir, PathBuf) {
	let (dir, real) = directory();
	let from = samples().join("bucket");
	fs::create_dir(real.join("nar")).unwrap();
	fs::copy(from.join("nix-cache-info"), real.join("nix-cache-info")).unwrap();
	for base in [LEAF, MIDDLE, SYSTEM] {
		if without.contains(&base) {
			continue;
		}
		let hash = base.split('-').next().unwrap();
		let narinfo = format!("{hash}.narinfo");
		let text = fs::read_to_string(from.join(&narinfo)).unwrap();
		let url = text.lines().find_map(|line| line.strip_prefix("URL: ")).unwrap();
		fs::copy(from.join(url), real.join(url)).unwrap();
		fs::write(real.join(narinfo), text).unwrap();
	}
	(dir, real)
}

/// A store under `nix daemon --force-trusted`, requiring signatures by the sample key.
pub struct TestDaemon {
	child: Child,
	dir: TempDir,
	socket: PathBuf,
}

impl TestDaemon {
	/// Starts the daemon, `upstream` its one substituter where given.
	pub async fn start(upstream: Option<&Path>) -> Self {
		let (dir, real) = directory();
		let socket = real.join("socket");
		let conf = real.join("conf");
		fs::create_dir(&conf).unwrap();
		fs::write(conf.join("nix.conf"), "").unwrap();
		let substituters =
			upstream.map(|path| format!("file://{}", path.display())).unwrap_or_default();
		let child = Command::new("nix")
			.args(["--extra-experimental-features", "nix-command daemon-trust-override", "daemon"])
			.arg("--force-trusted")
			.args(["--store", &format!("local?root={}", real.join("root").display())])
			.args(["--option", "require-sigs", "true"])
			.args(["--option", "trusted-public-keys", &trusted()])
			.args(["--option", "substituters", &substituters])
			.env("NIX_DAEMON_SOCKET_PATH", &socket)
			.env("NIX_CONF_DIR", &conf)
			.env("NIX_USER_CONF_FILES", conf.join("nix.conf"))
			.stdin(Stdio::null())
			.stdout(Stdio::null())
			.stderr(fs::File::create(real.join("log")).unwrap())
			.process_group(0)
			.spawn()
			.unwrap();
		let mut daemon = Self { child, dir, socket };
		for _ in 0..200 {
			if daemon.socket.exists() {
				return daemon;
			}
			if let Some(status) = daemon.child.try_wait().unwrap() {
				panic!("daemon exited {status}: {}", daemon.log());
			}
			tokio::time::sleep(Duration::from_millis(50)).await;
		}
		panic!("daemon socket never appeared: {}", daemon.log());
	}

	pub fn socket(&self) -> &Path {
		&self.socket
	}

	pub fn log(&self) -> String {
		fs::read_to_string(self.dir.path().join("log")).unwrap_or_default()
	}

	/// Whether the store holds a path, asked over a connection of its own.
	pub async fn valid(&self, base: &str) -> bool {
		let mut client = DaemonClientBuilder::new().connect_unix(&self.socket).await.unwrap();
		client.is_valid_path(&path(base)).await.unwrap()
	}
}

impl Drop for TestDaemon {
	fn drop(&mut self) {
		// The daemon forks a process per connection, so its whole group is stopped.
		let group = format!("-{}", self.child.id());
		let _ = Command::new("/bin/kill").args(["-KILL", "--", &group]).status();
		let _ = self.child.wait();
		writable(self.dir.path());
	}
}

/// Makes a tree writable again so it can be removed, the store having made it read only.
fn writable(path: &Path) {
	let Ok(meta) = fs::symlink_metadata(path) else { return };
	if meta.file_type().is_symlink() {
		return;
	}
	let mode = meta.permissions().mode() | 0o700;
	let _ = fs::set_permissions(path, fs::Permissions::from_mode(mode));
	if meta.is_dir()
		&& let Ok(entries) = fs::read_dir(path)
	{
		for entry in entries.flatten() {
			writable(&entry.path());
		}
	}
}
