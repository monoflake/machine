//! What the run does outside its own memory, each behind a trait a test replaces, RFC cbtjl. The
//! bucket and the store are written by the store lane, the units and the switch by the host lane.

use std::future::Future;
use std::pin::Pin;

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

/// The machine's clock.
pub trait Clock {
	/// Seconds since the epoch, UTC.
	fn now(&self) -> i64;
}
