//! Shared fixtures keep signatures real and effects observable.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::rc::Rc;

use harmonia_store_path::StorePath;
use machine_update::config::{Config, Paths};
use machine_update::effects::*;
use machine_update::output::Output;
use machine_update::{archive, flow, host};
use serde_json::{Value, json};

/// The incoming system used by the shell scenarios.
pub const NEW: &str = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system";
/// The system running before the first take.
pub const OLD: &str = "/nix/store/1123456789abcdfghijklmnpqrsvwxyz-system";

#[derive(Default)]
/// Canned objects and transport failures with an ordered request log.
pub struct BucketFake {
	/// The bucket objects by key.
	pub objects: RefCell<HashMap<String, Vec<u8>>>,
	/// The status by key, with zero representing a transport failure.
	pub errors: RefCell<HashMap<String, u16>>,
	/// The effects observed in call order.
	pub calls: RefCell<Vec<String>>,
}
impl Bucket for BucketFake {
	async fn get(&self, key: &str) -> Result<Option<Vec<u8>>, BucketError> {
		self.calls.borrow_mut().push(key.into());
		if let Some(code) = self.errors.borrow().get(key) {
			return if *code == 0 {
				Err(BucketError::Transport)
			} else {
				Err(BucketError::Status(*code))
			};
		}
		Ok(self.objects.borrow().get(key).cloned())
	}
	async fn open(&self, _: &str) -> Result<Option<Object>, BucketError> {
		Err(BucketError::Transport)
	}
}

#[derive(Default)]
/// An archive transport with observable requests.
pub struct Downloader {
	/// The downloaded archive bytes.
	pub bytes: RefCell<Vec<u8>>,
	/// The effects observed in call order.
	pub calls: RefCell<Vec<String>>,
	/// Whether the operation fails.
	pub fail: Cell<bool>,
}
impl Download for Downloader {
	async fn download(&self, url: &str) -> Result<Vec<u8>, BucketError> {
		self.calls.borrow_mut().push(url.into());
		if self.fail.get() { Err(BucketError::Transport) } else { Ok(self.bytes.borrow().clone()) }
	}
}

#[derive(Default)]
/// A store that records every requested realization.
pub struct StoreFake {
	/// The effects observed in call order.
	pub calls: Vec<StorePath>,
	/// Whether the operation fails.
	pub fail: bool,
}
impl Store for StoreFake {
	async fn realise(&mut self, system: &StorePath) -> Result<(), StoreError> {
		self.calls.push(system.clone());
		if self.fail {
			Err(StoreError { lines: system_diagnostic().lines().map(str::to_owned).collect() })
		} else {
			Ok(())
		}
	}
}

/// A switch that changes the running link only on success.
pub struct SwitchFake {
	/// The running system link.
	pub current: PathBuf,
	/// The next switches that fail.
	pub failures: RefCell<VecDeque<bool>>,
	/// The effects observed in call order.
	pub calls: RefCell<Vec<String>>,
	/// A profile to obstruct after a failed switch.
	pub obstruct_profile: RefCell<Option<PathBuf>>,
}
impl Switch for SwitchFake {
	async fn switch(&self, system: &StorePath) -> Result<(), SwitchError> {
		let path = format!("/nix/store/{system}");
		self.calls.borrow_mut().push(path.clone());
		if self.failures.borrow_mut().pop_front().unwrap_or(false) {
			if let Some(profile) = self.obstruct_profile.borrow_mut().take() {
				fs::remove_file(&profile).unwrap();
				fs::create_dir(profile).unwrap();
			}
			return Err(SwitchError { output: system_diagnostic() });
		}
		host::link(self.current.parent().unwrap(), "current-system", &path).unwrap();
		Ok(())
	}
}

fn system_diagnostic() -> String {
	diagnostic().replace("[systems]", "[other]\naws_access_key_id = ignored\n[systems]")
}

fn diagnostic() -> String {
	"https://private.example.invalid\n[systems]\naws_access_key_id = TESTACCESS\naws_secret_access_key = TEST/SECRET+=\n".into()
}

/// Canned unit jobs, active checks and results.
pub struct UnitsFake {
	/// The effects observed in call order.
	pub calls: RefCell<Vec<String>>,
	/// The next restart jobs that fail.
	pub restarts: RefCell<VecDeque<bool>>,
	/// The next active checks, followed by success.
	pub active: RefCell<VecDeque<bool>>,
	/// Whether the start job fails.
	pub start_failed: Cell<bool>,
	/// Whether the result is unreadable.
	pub result_failed: Cell<bool>,
}
impl Default for UnitsFake {
	fn default() -> Self {
		Self {
			calls: RefCell::default(),
			restarts: RefCell::default(),
			active: RefCell::default(),
			start_failed: Cell::new(false),
			result_failed: Cell::new(false),
		}
	}
}
impl Units for UnitsFake {
	async fn restart(&self, units: &[&str]) -> Result<(), UnitError> {
		self.calls.borrow_mut().push(format!("restart {}", units.join(" ")));
		if self.restarts.borrow_mut().pop_front().unwrap_or(false) {
			Err(UnitError::Bus(diagnostic()))
		} else {
			Ok(())
		}
	}
	async fn stop(&self, units: &[&str]) -> Result<(), UnitError> {
		self.calls.borrow_mut().push(format!("stop {}", units.join(" ")));
		Ok(())
	}
	async fn is_active(&self, unit: &str) -> Result<bool, UnitError> {
		self.calls.borrow_mut().push(format!("is-active {unit}"));
		Ok(self.active.borrow_mut().pop_front().unwrap_or(true))
	}
	async fn start(&self, unit: &str) -> Result<(), UnitError> {
		self.calls.borrow_mut().push(format!("start {unit}"));
		if self.start_failed.get() { Err(UnitError::Timeout) } else { Ok(()) }
	}
	async fn result(&self, unit: &str) -> Result<String, UnitError> {
		self.calls.borrow_mut().push(format!("result {unit}"));
		if self.result_failed.get() {
			Err(UnitError::Timeout)
		} else {
			Ok(if self.start_failed.get() { "exit-code" } else { "success" }.into())
		}
	}
}

/// The shell scenarios' fixed current time.
pub struct ClockFake;
impl Clock for ClockFake {
	fn now(&self) -> i64 {
		1_793_282_400
	}
}

#[derive(Clone, Default)]
/// A writer pair sharing one ordered transcript.
pub struct Capture(pub Rc<RefCell<Vec<u8>>>);
impl Write for Capture {
	fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
		self.0.borrow_mut().extend_from_slice(bytes);
		Ok(bytes.len())
	}
	fn flush(&mut self) -> io::Result<()> {
		Ok(())
	}
}
impl Capture {
	/// Reads the captured text.
	pub fn text(&self) -> String {
		String::from_utf8(self.0.borrow().clone()).unwrap()
	}
}

/// A temporary machine with real pointer signatures and replaceable effects.
pub struct Fixture {
	/// The directory holding the machine and throwaway keys.
	pub temporary: tempfile::TempDir,
	/// The run configuration.
	pub config: Config,
	/// The paths under the temporary machine.
	pub paths: Paths,
	/// The fake bucket.
	pub bucket: BucketFake,
	/// The fake archive transport.
	pub download: Downloader,
	/// The fake store.
	pub store: StoreFake,
	/// The fake switch.
	pub switch: SwitchFake,
	/// The fake systemd connection.
	pub units: UnitsFake,
	/// The exit codes and output of every fetch.
	pub transcript: Vec<(i32, String)>,
	/// Whether this fixture runs the driver channel.
	pub driver: bool,
}
impl Fixture {
	/// Creates the machine and its throwaway signing keys.
	pub fn new(driver: bool) -> Self {
		let temporary = tempfile::tempdir().unwrap();
		let root = temporary.path();
		for directory in ["state", "driver", "profiles"] {
			fs::create_dir(root.join(directory)).unwrap();
		}
		for key in ["ci", "mac"] {
			assert!(
				Command::new("ssh-keygen")
					.args(["-q", "-t", "ed25519", "-N", "", "-C", "", "-f"])
					.arg(root.join(key))
					.stdout(Stdio::null())
					.stderr(Stdio::null())
					.status()
					.unwrap()
					.success()
			);
		}
		let signers = root.join("signers");
		let namespace = if driver { "driver-pointer" } else { "system-pointer" };
		fs::write(
			&signers,
			format!("ci namespaces=\"{namespace}\" {}", fs::read_to_string(root.join("ci.pub")).unwrap()),
		)
		.unwrap();
		fs::write(root.join("endpoint"), "https://private.example.invalid\n").unwrap();
		fs::write(root.join("credentials"), "[other]\naws_access_key_id = ignored\n[systems]\naws_access_key_id = TESTACCESS\naws_secret_access_key = TEST/SECRET+=\n").unwrap();
		let paths = Paths {
			state: root.join("state"),
			current_system: root.join("current-system"),
			profile: root.join("profiles/system"),
			driver: root.join("driver"),
			daemon: root.join("socket"),
		};
		symlink(OLD, &paths.current_system).unwrap();
		host::set_profile(&paths.profile, OLD).unwrap();
		let config = Config {
			bucket: format!("file://{}", root.join("bucket").display()),
			machine: "c1".into(),
			credentials_file: root.join("credentials"),
			endpoint_file: root.join("endpoint"),
			signers: signers.clone(),
			driver_signers: signers,
			driver_channel: true,
			driver_builds: false,
			architecture: "x86_64-linux".into(),
			trusted: "fixture".into(),
		};
		let switch = SwitchFake {
			current: paths.current_system.clone(),
			failures: RefCell::default(),
			calls: RefCell::default(),
			obstruct_profile: RefCell::default(),
		};
		Self {
			temporary,
			config,
			paths,
			switch,
			bucket: BucketFake::default(),
			download: Downloader::default(),
			store: StoreFake::default(),
			units: UnitsFake::default(),
			transcript: Vec::new(),
			driver,
		}
	}
	/// The pointer key for this channel.
	pub fn key(&self) -> String {
		format!("pointer/{}/c1", if self.driver { "driver" } else { "system" })
	}
	/// Signs and publishes a pointer with the requested namespace and key.
	pub fn publish(&self, value: &Value, namespace: &str, signer: &str) {
		let message = self.temporary.path().join("message");
		fs::write(&message, serde_json::to_vec_pretty(value).unwrap()).unwrap();
		let sig = message.with_extension("sig");
		if sig.exists() {
			fs::remove_file(&sig).unwrap();
		}
		assert!(
			Command::new("ssh-keygen")
				.args(["-q", "-Y", "sign", "-f"])
				.arg(self.temporary.path().join(signer))
				.args(["-n", namespace])
				.arg(&message)
				.stdout(Stdio::null())
				.stderr(Stdio::null())
				.status()
				.unwrap()
				.success()
		);
		self.bucket.objects.borrow_mut().insert(self.key(), fs::read(message).unwrap());
		self.bucket.objects.borrow_mut().insert(format!("{}.sig", self.key()), fs::read(sig).unwrap());
	}
	/// Builds one system pointer for a scenario.
	pub fn system_pointer(&self, minute: u8, run: &str) -> Value {
		json!({"machine":"c1", "path":NEW, "at":format!("2026-10-29T13:{minute:02}:00Z"), "run":run})
	}
	/// Builds one driver pointer for a scenario.
	pub fn driver_pointer(&self, version: &str, minute: u8) -> Value {
		let archive = json!({"url":"https://private.example.invalid/archive", "sha256":archive::sha256(&self.download.bytes.borrow())});
		json!({"machine":"c1", "version":version, "at":format!("2026-10-29T13:{minute:02}:00Z"), "run":minute.to_string(), "archives":{"x86_64-linux":archive, "aarch64-linux":archive}})
	}
	/// Publishes a pointer signed by CI in this channel.
	pub fn signed(&self, value: &Value) {
		self.publish(value, if self.driver { "driver-pointer" } else { "system-pointer" }, "ci");
	}
	/// Runs one fetch and records its exit code and output.
	pub async fn fetch(&mut self, dry: bool) -> (i32, String) {
		let capture = Capture::default();
		let mut stdout = capture.clone();
		let mut stderr = capture.clone();
		let mut out = Output::new(&mut stdout, &mut stderr);
		let (_, secrets) =
			flow::access(&self.config, Some(&self.config.credentials_file), &mut out).unwrap();
		let code = if self.driver {
			flow::fetch_driver(
				&self.bucket,
				&self.download,
				&self.units,
				&self.config,
				&self.paths,
				&ClockFake,
				&secrets,
				dry,
				&mut out,
			)
			.await
		} else {
			flow::fetch_system(
				&self.bucket,
				&mut self.store,
				&self.switch,
				&self.config,
				&self.paths,
				&ClockFake,
				&secrets,
				dry,
				&mut out,
			)
			.await
		};
		let text = capture.text();
		for private in ["private.example.invalid", "TESTACCESS", "TEST/SECRET+="] {
			assert!(!text.contains(private));
		}
		for signer in ["ci.pub", "mac.pub"] {
			let key = fs::read_to_string(self.temporary.path().join(signer)).unwrap();
			assert!(!text.contains(key.trim()));
		}
		assert!(text.lines().all(|line| line.starts_with("update:")));
		self.transcript.push((code, text.clone()));
		(code, text)
	}
	/// Reads the accepted pointer bytes.
	pub fn accepted(&self) -> Vec<u8> {
		fs::read(self.paths.accepted()).unwrap()
	}
	/// The running system link.
	pub fn current(&self) -> Option<String> {
		host::read_link(&self.paths.driver.join("current")).unwrap()
	}
	/// Reads the previous driver link.
	pub fn previous(&self) -> Option<String> {
		host::read_link(&self.paths.driver.join("previous")).unwrap()
	}
	/// Restores the original running system and profile.
	pub fn reset_system(&self) {
		host::link(self.temporary.path(), "current-system", OLD).unwrap();
		host::set_profile(&self.paths.profile, OLD).unwrap();
	}
	/// Adds the throwaway Mac key to the allowed signers.
	pub fn trust_mac(&self) {
		let namespace = if self.driver { "driver-pointer" } else { "system-pointer" };
		let mut file = fs::OpenOptions::new().append(true).open(&self.config.signers).unwrap();
		writeln!(
			file,
			"mac namespaces=\"{namespace}\" {}",
			fs::read_to_string(self.temporary.path().join("mac.pub")).unwrap()
		)
		.unwrap();
	}
	/// Compares every run with the recorded shell transcript.
	pub fn compare(&self, sample: &str) {
		let mut expected = Vec::<(i32, String)>::new();
		for line in sample.lines() {
			if line.starts_with("### run ") {
				let code = line.rsplit("exit ").next().unwrap().parse().unwrap();
				expected.push((code, String::new()));
			} else {
				let text = &mut expected.last_mut().unwrap().1;
				text.push_str(line);
				text.push('\n');
			}
		}

		assert_eq!(self.transcript.len(), expected.len());
		for (i, ((actual_code, actual), (code, wanted))) in
			self.transcript.iter().zip(expected.iter()).enumerate()
		{
			assert_eq!(actual_code, code, "run {}", i + 1);
			let actual = actual
				.replace("update: systemd unreachable: https://<endpoint>", "update: https://<endpoint>");
			assert_eq!(&actual, wanted, "run {}", i + 1);
		}
	}
}

/// Builds one gzip tar with the given member and executable mode.
pub fn archive_file(name: &str, mode: u32, kind: tar::EntryType) -> Vec<u8> {
	let gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
	let mut archive = tar::Builder::new(gzip);
	let mut header = tar::Header::new_gnu();
	header.set_path(name).unwrap();
	header.set_entry_type(kind);
	header.set_mode(mode);
	let contents = if kind.is_file() { b"#!/bin/sh\nexit 0\n".as_slice() } else { b"".as_slice() };
	header.set_size(u64::try_from(contents.len()).unwrap());
	if kind.is_symlink() {
		header.set_link_name("target").unwrap();
	}
	header.set_cksum();
	archive.append(&header, contents).unwrap();
	archive.into_inner().unwrap().finish().unwrap()
}

/// Records files and links for an unchanged tree assertion.
pub fn tree(root: &Path) -> Vec<(PathBuf, Vec<u8>)> {
	let mut entries = Vec::new();
	for entry in fs::read_dir(root).unwrap() {
		let entry = entry.unwrap();
		let kind = entry.file_type().unwrap();
		let bytes = if kind.is_symlink() {
			fs::read_link(entry.path()).unwrap().as_os_str().as_encoded_bytes().to_vec()
		} else if kind.is_file() {
			fs::read(entry.path()).unwrap()
		} else {
			Vec::new()
		};
		entries.push((entry.path(), bytes));
		if kind.is_dir() {
			entries.extend(tree(&entry.path()));
		}
	}
	entries.sort();
	entries
}
