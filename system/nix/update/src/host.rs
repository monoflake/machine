//! The machine the run changes, systemd over D-Bus, the switch, the clock, the system profile, the
//! driver's links and lock.

use std::cell::Cell;
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use futures_util::{Stream, StreamExt};
use harmonia_store_path::{StoreDir, StorePath};
use rustix::fs::{FlockOperation, flock, fstat};
use zbus::OwnedObjectPath;
use zbus::{Connection, Proxy};

use crate::effects::{Boot, Clock, Freeze, Program, Ran, Switch, SwitchError, UnitError, Units};

const DESTINATION: &str = "org.freedesktop.systemd1";
const MANAGER_PATH: &str = "/org/freedesktop/systemd1";
const MANAGER: &str = "org.freedesktop.systemd1.Manager";
const UNIT: &str = "org.freedesktop.systemd1.Unit";
const SERVICE: &str = "org.freedesktop.systemd1.Service";
const NO_SUCH_UNIT: &str = "org.freedesktop.systemd1.NoSuchUnit";

/// How long a restart or a stop waits for its jobs.
const JOB_LIMIT: Duration = Duration::from_secs(40);

/// A job systemd announced as removed, its object path and its result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Removed {
	/// The job's object path.
	pub job: String,
	/// How the job ended, `done` or `skipped` when it succeeded.
	pub result: String,
}

/// The jobs a call is still waiting on, each by its object path and the unit it was asked for.
#[derive(Debug, Default)]
pub struct Jobs {
	waiting: HashMap<String, String>,
}

impl Jobs {
	/// Starts waiting on a job.
	pub fn add(&mut self, job: &str, unit: &str) {
		self.waiting.insert(job.to_owned(), unit.to_owned());
	}

	/// Whether every job has ended.
	pub fn is_empty(&self) -> bool {
		self.waiting.is_empty()
	}

	/// Takes in a removed job, passing over unrequested jobs and refusing failed results.
	pub fn removed(&mut self, removed: &Removed) -> Result<(), UnitError> {
		let Some(unit) = self.waiting.remove(&removed.job) else {
			return Ok(());
		};
		if matches!(removed.result.as_str(), "done" | "skipped") {
			return Ok(());
		}
		Err(UnitError::Job { unit, result: removed.result.clone() })
	}
}

/// Reads removals until every job has ended, `limit` the longest it waits.
pub async fn wait_removed(
	mut removals: impl Stream<Item = Removed> + Unpin,
	mut jobs: Jobs,
	limit: Option<Duration>,
) -> Result<(), UnitError> {
	let wait = async {
		while !jobs.is_empty() {
			let Some(removed) = removals.next().await else {
				return Err(UnitError::Bus("signal stream ended".to_owned()));
			};
			jobs.removed(&removed)?;
		}
		Ok(())
	};
	match limit {
		Some(limit) => tokio::time::timeout(limit, wait).await.unwrap_or(Err(UnitError::Timeout)),
		None => wait.await,
	}
}

/// Whether a unit's `ActiveState` counts as active.
pub fn is_active_state(state: &str) -> bool {
	matches!(state, "active" | "reloading" | "refreshing")
}

fn bus(error: impl std::fmt::Display) -> UnitError {
	UnitError::Bus(error.to_string())
}

/// Interprets the manager's reply to a subscription request.
pub fn subscription(reply: Result<(), zbus::Error>) -> Result<(), UnitError> {
	match reply {
		Err(zbus::Error::MethodError(name, _, _))
			if matches!(
				name.as_str(),
				"org.freedesktop.systemd1.AlreadySubscribed" | "org.freedesktop.DBus.Error.AccessDenied"
			) =>
		{
			Ok(())
		}
		other => other.map_err(bus),
	}
}

fn is_no_such_unit(error: &zbus::Error) -> bool {
	matches!(error, zbus::Error::MethodError(name, _, _) if name.as_str() == NO_SUCH_UNIT)
}

/// systemd's manager on the system bus.
#[derive(Debug)]
pub struct Systemd {
	connection: Connection,
}

impl Systemd {
	/// Connects to the system bus.
	pub async fn connect() -> Result<Self, UnitError> {
		let connection = Connection::system().await.map_err(bus)?;
		Ok(Self { connection })
	}

	async fn manager(&self) -> Result<Proxy<'_>, UnitError> {
		Proxy::new(&self.connection, DESTINATION, MANAGER_PATH, MANAGER).await.map_err(bus)
	}

	async fn unit_proxy(
		&self,
		path: OwnedObjectPath,
		interface: &'static str,
	) -> Result<Proxy<'_>, UnitError> {
		Proxy::new(&self.connection, DESTINATION, path, interface).await.map_err(bus)
	}

	/// Asks `method` (`RestartUnit`, `StopUnit` or `StartUnit`) of each unit, with the signal
	/// subscribed first so no removal is missed, and waits for the jobs.
	async fn run_jobs(
		&self,
		method: &str,
		units: &[&str],
		limit: Option<Duration>,
	) -> Result<(), UnitError> {
		let manager = self.manager().await?;
		let signals = manager.receive_signal("JobRemoved").await.map_err(bus)?;
		subscription(manager.call_method("Subscribe", &()).await.map(|_| ()))?;
		let removals = signals.filter_map(|message| async move {
			let body = message.body();
			let (_, job, _, result) =
				body.deserialize::<(u32, OwnedObjectPath, String, String)>().ok()?;
			Some(Removed { job: job.as_str().to_owned(), result })
		});
		let removals = Box::pin(removals);
		let ask = async {
			let mut jobs = Jobs::default();
			for unit in units {
				let job: OwnedObjectPath = manager.call(method, &(*unit, "replace")).await.map_err(bus)?;
				jobs.add(job.as_str(), unit);
			}
			Ok::<_, UnitError>(jobs)
		};
		let waited = async {
			let jobs = ask.await?;
			wait_removed(removals, jobs, None).await
		};
		match limit {
			Some(limit) => tokio::time::timeout(limit, waited).await.unwrap_or(Err(UnitError::Timeout)),
			None => waited.await,
		}
	}
}

impl Units for Systemd {
	async fn restart(&self, units: &[&str]) -> Result<(), UnitError> {
		self.run_jobs("RestartUnit", units, Some(JOB_LIMIT)).await
	}

	async fn stop(&self, units: &[&str]) -> Result<(), UnitError> {
		self.run_jobs("StopUnit", units, Some(JOB_LIMIT)).await
	}

	async fn is_active(&self, unit: &str) -> Result<bool, UnitError> {
		let manager = self.manager().await?;
		let path: OwnedObjectPath = match manager.call("GetUnit", &(unit,)).await {
			Ok(path) => path,
			Err(error) if is_no_such_unit(&error) => return Ok(false),
			Err(error) => return Err(bus(error)),
		};
		let proxy = self.unit_proxy(path, UNIT).await?;
		let state: String = proxy.get_property("ActiveState").await.map_err(bus)?;
		Ok(is_active_state(&state))
	}

	async fn start(&self, unit: &str) -> Result<(), UnitError> {
		self.run_jobs("StartUnit", &[unit], None).await
	}

	async fn result(&self, unit: &str) -> Result<String, UnitError> {
		let manager = self.manager().await?;
		let path: OwnedObjectPath = manager.call("LoadUnit", &(unit,)).await.map_err(bus)?;
		let proxy = self.unit_proxy(path, SERVICE).await?;
		proxy.get_property("Result").await.map_err(bus)
	}

	async fn identity(&self, unit: &str) -> Result<(u32, u32), UnitError> {
		let manager = self.manager().await?;
		let path: OwnedObjectPath = manager.call("LoadUnit", &(unit,)).await.map_err(bus)?;
		let proxy = self.unit_proxy(path, SERVICE).await?;
		let pid: u32 = proxy.get_property("MainPID").await.map_err(bus)?;
		let restarts: u32 = proxy.get_property("NRestarts").await.map_err(bus)?;
		Ok((pid, restarts))
	}
}

/// The system's own `switch-to-configuration`, run as a child.
#[derive(Debug, Default)]
pub struct Process {
	store_dir: StoreDir,
}

impl Process {
	/// A process that finds systems under another store directory than `/nix/store`.
	pub fn in_store(store_dir: StoreDir) -> Self {
		Self { store_dir }
	}
}

impl Switch for Process {
	async fn switch(&self, system: &StorePath) -> Result<(), SwitchError> {
		let program = system.to_absolute_path(&self.store_dir).join("bin/switch-to-configuration");
		let (output, status) = run_merged(&program, "switch")
			.await
			.map_err(|error| SwitchError { output: error.to_string() })?;
		if status { Ok(()) } else { Err(SwitchError { output }) }
	}
}

/// A file taking a child's output and error in write order, unlinked at once, and a reader.
fn merged_output() -> io::Result<(File, File)> {
	loop {
		let path = std::env::temp_dir().join(format!(
			"machine-update.{}.{}",
			std::process::id(),
			STAGING.fetch_add(1, Ordering::Relaxed)
		));
		match OpenOptions::new().read(true).append(true).create_new(true).mode(0o600).open(&path) {
			Ok(file) => {
				let reader = File::open(&path)?;
				std::fs::remove_file(path)?;
				return Ok((file, reader));
			}
			Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
			Err(error) => return Err(error),
		}
	}
}

/// What was written so far, as a descendant may still write past the parent's exit.
fn written_so_far(output: &File, reader: File) -> io::Result<String> {
	let mut bytes = Vec::new();
	let length = output.metadata()?.len();
	reader.take(length).read_to_end(&mut bytes)?;
	Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Runs a program with one argument, merging its output in write order and waiting for its exit.
pub async fn run_merged(program: &Path, argument: &str) -> io::Result<(String, bool)> {
	let (output, reader) = merged_output()?;
	let status = tokio::process::Command::new(program)
		.arg(argument)
		.stdin(Stdio::null())
		.stdout(Stdio::from(output.try_clone()?))
		.stderr(Stdio::from(output.try_clone()?))
		.status()
		.await?;
	Ok((written_so_far(&output, reader)?, status.success()))
}

/// The driver's own program, run as a child and killed past its limit.
#[derive(Debug, Default)]
pub struct Child;

impl Program for Child {
	async fn run(&self, program: &Path, args: &[String], limit: Duration) -> Ran {
		let unstarted = |error: io::Error| Ran::Unstarted(error.to_string());
		let (output, reader) = match merged_output() {
			Ok(files) => files,
			Err(error) => return unstarted(error),
		};
		let (out, err) = match (output.try_clone(), output.try_clone()) {
			(Ok(out), Ok(err)) => (out, err),
			(Err(error), _) | (_, Err(error)) => return unstarted(error),
		};
		let spawned = tokio::process::Command::new(program)
			.args(args)
			.stdin(Stdio::null())
			.stdout(Stdio::from(out))
			.stderr(Stdio::from(err))
			.kill_on_drop(true)
			.spawn();
		let mut child = match spawned {
			Ok(child) => child,
			Err(error) => return unstarted(error),
		};
		let waited = tokio::time::timeout(limit, child.wait()).await;
		if waited.is_err() {
			let _ = child.kill().await;
		}
		let written = written_so_far(&output, reader).unwrap_or_default();
		match waited {
			Ok(Ok(status)) => Ran::Exited { code: status.code(), output: written },
			Ok(Err(error)) => unstarted(error),
			Err(_) => Ran::TimedOut { output: written },
		}
	}
}

/// What `mountinfo` says of the mount at `point`: its filesystem type when it is a filesystem of
/// its own, `None` when nothing is mounted there or it shares its device with the root, as a bind
/// of a directory of it, which freezing would take with the root.
pub fn own_mount(mountinfo: &str, point: &str) -> Option<String> {
	let mut at_point = None;
	let mut root_device = None;
	for (device, mounted, kind) in mountinfo.lines().filter_map(mount_fields) {
		// The last mount at a path is the one that shows.
		if mounted == point {
			at_point = Some((device, kind));
		}
		if mounted == "/" {
			root_device = Some(device);
		}
	}
	let (device, kind) = at_point?;
	(root_device != Some(device)).then(|| kind.to_owned())
}

/// A mount table line's device, mount point and filesystem type.
fn mount_fields(line: &str) -> Option<(&str, String, &str)> {
	let (before, after) = line.split_once(" - ")?;
	let mut fields = before.split(' ');
	let device = fields.nth(2)?;
	let mounted = unescape(fields.nth(1)?);
	Some((device, mounted, after.split(' ').next()?))
}

/// A mount point as `mountinfo` escapes it, `\040` for a space.
fn unescape(field: &str) -> String {
	let bytes = field.as_bytes();
	let mut out = Vec::with_capacity(bytes.len());
	let mut i = 0;
	while i < bytes.len() {
		let octal = bytes.get(i..i + 4).and_then(|four| {
			let digits = four.strip_prefix(b"\\")?;
			digits
				.iter()
				.try_fold(0_u32, |n, d| (b'0'..=b'7').contains(d).then(|| n * 8 + u32::from(d - b'0')))
		});
		match octal.and_then(|n| u8::try_from(n).ok()) {
			Some(byte) => {
				out.push(byte);
				i += 4;
			}
			None => {
				out.extend(bytes.get(i));
				i += 1;
			}
		}
	}
	String::from_utf8_lossy(&out).into_owned()
}

/// The machine's `/boot`, found in the mount table and frozen by the kernel's `FIFREEZE`.
#[derive(Debug)]
pub struct BootMount {
	mountinfo: PathBuf,
	point: PathBuf,
	held: std::cell::RefCell<Option<File>>,
	frozen: Cell<bool>,
}

impl BootMount {
	/// A `/boot` found at `point` in the mount table `mountinfo`.
	pub fn at(mountinfo: &Path, point: &Path) -> Self {
		Self {
			mountinfo: mountinfo.to_owned(),
			point: point.to_owned(),
			held: std::cell::RefCell::new(None),
			frozen: Cell::new(false),
		}
	}
}

impl Default for BootMount {
	fn default() -> Self {
		Self::at(Path::new("/proc/self/mountinfo"), Path::new("/boot"))
	}
}

impl Boot for BootMount {
	fn freeze(&self) -> io::Result<Freeze> {
		let point = self.point.to_str().ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
		let table = std::fs::read_to_string(&self.mountinfo)?;
		let Some(kind) = own_mount(&table, point) else {
			return Ok(Freeze::NotMounted);
		};
		let file = File::open(&self.point)?;
		match machine_update_abort::freeze::freeze(&file) {
			Ok(()) => {
				self.frozen.set(true);
				*self.held.borrow_mut() = Some(file);
				Ok(Freeze::Held)
			}
			// A filesystem with no freeze answers one of these, as vfat does.
			Err(error)
				if error.kind() == io::ErrorKind::Unsupported
					|| error.raw_os_error().map(rustix::io::Errno::from_raw_os_error).is_some_and(
						|errno| errno == rustix::io::Errno::NOTTY || errno == rustix::io::Errno::NOTSUP,
					) =>
			{
				Ok(Freeze::Unsupported(kind))
			}
			Err(error) => Err(error),
		}
	}

	fn thaw(&self) -> io::Result<()> {
		let held = self.held.borrow_mut().take();
		let Some(file) = held else {
			return Ok(());
		};
		let thawed = machine_update_abort::freeze::thaw(&file);
		if thawed.is_ok() {
			self.frozen.set(false);
		} else {
			*self.held.borrow_mut() = Some(file);
		}
		thawed
	}
}

impl Drop for BootMount {
	fn drop(&mut self) {
		if self.frozen.get() {
			let _ = self.thaw();
		}
	}
}

/// The machine's real clock.
#[derive(Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
	fn now(&self) -> i64 {
		match SystemTime::now().duration_since(UNIX_EPOCH) {
			Ok(since) => i64::try_from(since.as_secs()).unwrap_or(i64::MAX),
			Err(before) => -i64::try_from(before.duration().as_secs()).unwrap_or(i64::MAX),
		}
	}
}

/// Returns a link's target, or `None` for a missing path or a path that is not a link.
/// Other failures return an error.
pub fn read_link(link: &Path) -> io::Result<Option<String>> {
	match std::fs::read_link(link) {
		Ok(target) => target
			.into_os_string()
			.into_string()
			.map(Some)
			.map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "link target is not UTF-8")),
		Err(error)
			if matches!(
				error.kind(),
				io::ErrorKind::NotFound | io::ErrorKind::InvalidInput | io::ErrorKind::NotADirectory
			) =>
		{
			Ok(None)
		}
		Err(error) => Err(error),
	}
}

static STAGING: AtomicU64 = AtomicU64::new(0);

/// Points `<dir>/<name>` at `target` by a link made beside it and renamed over it.
fn replace_link(dir: &Path, name: &str, target: &str) -> io::Result<()> {
	let staging =
		dir.join(format!(".{name}.{}.{}", std::process::id(), STAGING.fetch_add(1, Ordering::Relaxed)));
	std::os::unix::fs::symlink(target, &staging)?;
	std::fs::rename(&staging, dir.join(name)).inspect_err(|_| {
		let _ = std::fs::remove_file(&staging);
	})
}

/// The generation a name in a profile's directory stands for, `<profile>-<n>-link`.
fn generation(profile: &str, name: &str) -> Option<u64> {
	name.strip_prefix(profile)?.strip_prefix('-')?.strip_suffix("-link")?.parse().ok()
}

/// Sets a profile as `nix-env --set` does, a new `<profile>-<n>-link` beside it unless the last
/// already points there, then the profile's link renamed over to it.
pub fn set_profile(profile: &Path, target: &str) -> io::Result<()> {
	let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "profile has no directory or name");
	let dir = profile.parent().ok_or_else(invalid)?;
	let name = profile.file_name().and_then(|name| name.to_str()).ok_or_else(invalid)?;
	let _lock = lock(&dir.join(format!("{name}.lock")))?;
	let mut last = None::<u64>;
	for entry in std::fs::read_dir(dir)? {
		let entry = entry?;
		let found = entry.file_name().to_str().and_then(|entry| generation(name, entry));
		last = last.max(found);
	}
	let reused = match last {
		Some(n) => {
			let current = read_link(&dir.join(format!("{name}-{n}-link")))?;
			(current.as_deref() == Some(target)).then_some(n)
		}
		None => None,
	};
	let n = match reused {
		Some(n) => n,
		None => {
			let n = last.map_or(1, |n| n + 1);
			replace_link(dir, &format!("{name}-{n}-link"), target)?;
			n
		}
	};
	replace_link(dir, name, &format!("{name}-{n}-link"))
}

/// Points `<root>/<name>` at `target` by a link made beside it and renamed over it.
pub fn link(root: &Path, name: &str, target: &str) -> io::Result<()> {
	replace_link(root, name, target)
}

/// An exclusive lock on a file, held until dropped.
#[derive(Debug)]
pub struct Lock {
	file: File,
}

impl Drop for Lock {
	fn drop(&mut self) {
		let _ = flock(&self.file, FlockOperation::Unlock);
	}
}

/// Takes an exclusive lock on a file, creating it, waiting while another holds it.
pub fn lock(file: &Path) -> io::Result<Lock> {
	loop {
		let file = OpenOptions::new().create(true).truncate(false).write(true).open(file)?;
		loop {
			match flock(&file, FlockOperation::LockExclusive) {
				Ok(()) => break,
				Err(rustix::io::Errno::INTR) => {}
				Err(errno) => return Err(errno.into()),
			}
		}
		// A previous holder may have retired this inode while the lock was waiting.
		let stat = fstat(&file)?;
		if stat.st_size == 0 && stat.st_nlink != 0 {
			return Ok(Lock { file });
		}
	}
}
