//! The updater's runtime configuration and real effects.

use std::path::Path;

use harmonia_store_path::StorePath;
use machine_update::bucket::{Https, Remote};
use machine_update::config::{Config, Instance, Paths};
use machine_update::effects::{Bucket, BucketError, Object, Store, StoreError};
use machine_update::host::{Process, SystemClock};
use machine_update::output::{Output, Refusal};
use machine_update::{flow, store::Daemon, tls};

struct ReadBucket<'a>(&'a Remote);

impl Bucket for ReadBucket<'_> {
	async fn get(&self, key: &str) -> Result<Option<Vec<u8>>, BucketError> {
		self.0.get(key).await
	}
	async fn open(&self, key: &str) -> Result<Option<Object>, BucketError> {
		self.0.open(key).await
	}
}

struct Connection<'a> {
	remote: &'a Remote,
	paths: &'a Paths,
	trusted: &'a str,
	daemon: Option<Daemon<ReadBucket<'a>>>,
}

impl Store for Connection<'_> {
	async fn realise(&mut self, system: &StorePath) -> Result<(), StoreError> {
		if self.daemon.is_none() {
			self.daemon =
				Some(Daemon::connect(&self.paths.daemon, ReadBucket(self.remote), self.trusted).await?);
		}
		match self.daemon.as_mut() {
			Some(daemon) => daemon.realise(system).await,
			None => Err(StoreError { lines: vec!["daemon unavailable".into()] }),
		}
	}
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::process::ExitCode {
	tls::install();
	rustix::process::umask(rustix::fs::Mode::from_raw_mode(0o077));
	let mut stdout = std::io::stdout();
	let mut stderr = std::io::stderr();
	let mut out = Output::new(&mut stdout, &mut stderr);
	let code = run(&mut out).await;
	if code == 0 { std::process::ExitCode::SUCCESS } else { std::process::ExitCode::FAILURE }
}

async fn run(out: &mut Output<'_>) -> i32 {
	let args: Vec<String> = std::env::args().skip(1).collect();
	let (instance, dry) = match flow::arguments(&args) {
		Ok(args) => args,
		Err(reason) => {
			out.refuse(reason);
			return 1;
		}
	};
	let config = std::env::var_os("MACHINE_UPDATE_CONFIG").and_then(|path| std::fs::read(path).ok());
	let config: Config = match config.and_then(|bytes| serde_json::from_slice(&bytes).ok()) {
		Some(config) => config,
		None => {
			out.refuse(Refusal::Fields);
			return 1;
		}
	};
	let Some(state) = std::env::var_os("STATE_DIRECTORY") else {
		out.refuse(Refusal::State);
		return 1;
	};
	let paths = Paths::machine(Path::new(&state));
	let credentials = std::env::var_os("AWS_SHARED_CREDENTIALS_FILE");
	let (remote, secrets) = match flow::access(&config, credentials.as_deref().map(Path::new), out) {
		Ok(access) => access,
		Err(reason) => {
			out.refuse(reason);
			return 1;
		}
	};
	match instance {
		Instance::System => {
			let mut store =
				Connection { remote: &remote, paths: &paths, trusted: &config.trusted, daemon: None };
			flow::fetch_system(
				&remote,
				&mut store,
				&Process::default(),
				&config,
				&paths,
				&SystemClock,
				&secrets,
				dry,
				out,
			)
			.await
		}
		Instance::Driver => {
			flow::fetch_driver(
				&remote,
				&Https,
				&Bus::new(),
				&config,
				&paths,
				&SystemClock,
				&secrets,
				dry,
				out,
			)
			.await
		}
	}
}

use machine_update::effects::{UnitError, Units};
use machine_update::host::Systemd;
use tokio::sync::OnceCell;

struct Bus(OnceCell<Systemd>);

impl Bus {
	fn new() -> Self {
		Self(OnceCell::new())
	}
	async fn connection(&self) -> Result<&Systemd, UnitError> {
		self.0.get_or_try_init(Systemd::connect).await
	}
}

impl Units for Bus {
	async fn restart(&self, units: &[&str]) -> Result<(), UnitError> {
		self.connection().await?.restart(units).await
	}
	async fn stop(&self, units: &[&str]) -> Result<(), UnitError> {
		self.connection().await?.stop(units).await
	}
	async fn is_active(&self, unit: &str) -> Result<bool, UnitError> {
		self.connection().await?.is_active(unit).await
	}
	async fn start(&self, unit: &str) -> Result<(), UnitError> {
		self.connection().await?.start(unit).await
	}
	async fn result(&self, unit: &str) -> Result<String, UnitError> {
		self.connection().await?.result(unit).await
	}
}
