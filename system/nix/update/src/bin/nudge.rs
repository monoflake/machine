//! The forced SSH command with the machine's systemd connection.

use machine_update::config::Paths;
use machine_update::output::Output;
use machine_update::{flow, tls};

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::process::ExitCode {
	tls::install();
	let mut stdout = std::io::stdout();
	let mut stderr = std::io::stderr();
	let paths = Paths::machine(std::path::Path::new("/var/lib/machine-update"));
	let command = std::env::var("SSH_ORIGINAL_COMMAND").unwrap_or_default();
	let code =
		flow::nudge(&command, &Bus::new(), &paths, &mut Output::new(&mut stdout, &mut stderr)).await;
	if code == 0 { std::process::ExitCode::SUCCESS } else { std::process::ExitCode::FAILURE }
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
