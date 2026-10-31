//! The machine the run changes, systemd over D-Bus, the switch, the clock, the system profile, the
//! driver's links and lock.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use futures_util::{Stream, StreamExt};
use harmonia_store_path::{StoreDir, StorePath};
use rustix::fs::{FlockOperation, flock, fstat};
use zbus::OwnedObjectPath;
use zbus::{Connection, Proxy};

use crate::effects::{Clock, Switch, SwitchError, UnitError, Units};

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
			if name.as_str() == "org.freedesktop.systemd1.AlreadySubscribed" =>
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

/// Runs a program with one argument, merging its output in write order and waiting for its exit.
pub async fn run_merged(program: &Path, argument: &str) -> io::Result<(String, bool)> {
	let (output, reader) = loop {
		let path = std::env::temp_dir().join(format!(
			"machine-update.{}.{}",
			std::process::id(),
			STAGING.fetch_add(1, Ordering::Relaxed)
		));
		match OpenOptions::new().read(true).append(true).create_new(true).mode(0o600).open(&path) {
			Ok(file) => {
				let reader = File::open(&path)?;
				std::fs::remove_file(path)?;
				break (file, reader);
			}
			Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
			Err(error) => return Err(error),
		}
	};
	let status = tokio::process::Command::new(program)
		.arg(argument)
		.stdin(Stdio::null())
		.stdout(Stdio::from(output.try_clone()?))
		.stderr(Stdio::from(output.try_clone()?))
		.status()
		.await?;
	let mut bytes = Vec::new();
	// A descendant may still write, so only read the bytes present at the parent's exit.
	let length = output.metadata()?.len();
	reader.take(length).read_to_end(&mut bytes)?;
	Ok((String::from_utf8_lossy(&bytes).into_owned(), status.success()))
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

/// Where a link points, `None` where there is no link. A path that exists and is not a link also
/// gives `None`, as the shell's `readlink x || current=` did; any other failure is an error.
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
