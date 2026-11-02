//! What the run does outside its own memory, each behind a trait a test replaces, RFC cbtjl. The
//! bucket and the store are written by the store lane, the units and the switch by the host lane.

use std::future::Future;
use std::io;
use std::path::Path;
use std::pin::Pin;
use std::time::Duration;

use harmonia_store_path::StorePath;
use tokio::io::AsyncRead;

/// An object being read from the bucket.
pub type Object = Pin<Box<dyn AsyncRead + Send>>;

/// The bucket, read with the systems credentials or from a directory in a test.
pub trait Bucket {
	/// Reads a small object whole, `None` where the bucket answers that it has none.
	fn get(&self, key: &str) -> impl Future<Output = Result<Option<Vec<u8>>, BucketError>>;

	/// Opens an object to stream, `None` where the bucket answers that it has none.
	fn open(&self, key: &str) -> impl Future<Output = Result<Option<Object>, BucketError>>;
}

/// Why the bucket answered no object, other than its having none.
#[derive(Debug, thiserror::Error)]
pub enum BucketError {
	/// The bucket answered with a status other than 200 and 404.
	#[error("bucket answered {0}")]
	Status(u16),
	/// The bucket was not reached, or the object not read whole.
	#[error("bucket unreachable")]
	Transport,
}

/// A driver archive outside the bucket, read over HTTPS alone, a redirect to HTTPS alone.
pub trait Download {
	/// Reads the archive whole.
	fn download(&self, url: &str) -> impl Future<Output = Result<Vec<u8>, BucketError>>;
}

/// The Nix store, reached through its daemon.
pub trait Store {
	/// Makes a system's closure valid from the bucket or else upstream, building nothing, and holds
	/// a temporary root on the system until the store is dropped.
	fn realise(&mut self, system: &StorePath) -> impl Future<Output = Result<(), StoreError>>;
}

/// Why a closure could not be made valid, its lines printed masked before the refusal.
#[derive(Debug, thiserror::Error)]
#[error("{}", .lines.join("\n"))]
pub struct StoreError {
	/// What went wrong, one line each, the last five printed.
	pub lines: Vec<String>,
}

/// systemd, reached over D-Bus.
pub trait Units {
	/// Restarts each unit and waits up to 40 seconds for their jobs to end.
	fn restart(&self, units: &[&str]) -> impl Future<Output = Result<(), UnitError>>;

	/// Stops each unit and waits up to 40 seconds for their jobs to end.
	fn stop(&self, units: &[&str]) -> impl Future<Output = Result<(), UnitError>>;

	/// Whether a unit is active.
	fn is_active(&self, unit: &str) -> impl Future<Output = Result<bool, UnitError>>;

	/// Starts a unit and waits for its job to end, a oneshot's job ending with the service.
	fn start(&self, unit: &str) -> impl Future<Output = Result<(), UnitError>>;

	/// A unit's `Result`, as `success` or `exit-code`.
	fn result(&self, unit: &str) -> impl Future<Output = Result<String, UnitError>>;

	/// A service's `MainPID` and `NRestarts`, which change where it ended and started again.
	fn identity(&self, unit: &str) -> impl Future<Output = Result<(u32, u32), UnitError>>;
}

/// Why systemd did not do what was asked.
#[derive(Debug, thiserror::Error)]
pub enum UnitError {
	/// A job ended other than done.
	#[error("job for {unit} ended {result}")]
	Job {
		/// The unit.
		unit: String,
		/// The job's result, as `failed` or `timeout`.
		result: String,
	},
	/// The jobs did not end within their time.
	#[error("jobs did not end in time")]
	Timeout,
	/// systemd was not reached, or refused the call.
	#[error("systemd unreachable: {0}")]
	Bus(String),
}

/// The one program the run starts, a system's own `switch-to-configuration`.
pub trait Switch {
	/// Runs `<system>/bin/switch-to-configuration switch` and waits for it.
	fn switch(&self, system: &StorePath) -> impl Future<Output = Result<(), SwitchError>>;
}

/// A switch that failed, its output printed masked.
#[derive(Debug, thiserror::Error)]
#[error("switch failed")]
pub struct SwitchError {
	/// Its standard output and error, interleaved as written.
	pub output: String,
}

/// The filesystem holding `/boot`, brought to rest once a switch has written the boot loader's
/// files, so a power cut cannot leave the loader reading what the journal has not yet put in place.
pub trait Boot {
	/// Freezes `/boot`, which commits its journal and writes it into place.
	fn freeze(&self) -> io::Result<Freeze>;

	/// Thaws `/boot` after a freeze that held.
	fn thaw(&self) -> io::Result<()>;

	/// Writes out `/boot`'s filesystem by `syncfs`, which puts one with no journal in place, as vfat.
	fn sync(&self) -> io::Result<()>;
}

/// What a freeze of `/boot` came to, other than failing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Freeze {
	/// `/boot` is frozen and awaits its thaw.
	Held,
	/// `/boot` is no mount of its own, so freezing it would freeze the root.
	NotMounted,
	/// The filesystem, named by its type, cannot be frozen, as vfat.
	Unsupported(String),
}

/// How a program the run started ended, its standard output and error interleaved as written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ran {
	/// It exited, by its code, none where a signal ended it.
	Exited {
		/// The exit code.
		code: Option<i32>,
		/// What it wrote.
		output: String,
	},
	/// It outlived its limit and was killed.
	TimedOut {
		/// What it wrote before.
		output: String,
	},
	/// It could not be started, and why.
	Unstarted(String),
}

/// The driver's own program, run to judge an update, RFC okz12.
pub trait Program {
	/// Runs it with its arguments, killing it past the limit.
	fn run(&self, program: &Path, args: &[String], limit: Duration) -> impl Future<Output = Ran>;
}

/// The machine's clock.
pub trait Clock {
	/// Seconds since the epoch, UTC.
	fn now(&self) -> i64;
}
