//! The machine the run changes, systemd over D-Bus, the switch, the clock, the system profile, the
//! driver's links and lock. Written by the host lane.
#![allow(unused_variables, dead_code)]

use std::io;
use std::path::Path;

use harmonia_store_path::StorePath;

use crate::effects::{Clock, Switch, SwitchError, UnitError, Units};

/// systemd's manager on the system bus.
#[derive(Debug)]
pub struct Systemd;

impl Systemd {
	/// Connects to the system bus.
	pub async fn connect() -> Result<Self, UnitError> {
		todo!()
	}
}

impl Units for Systemd {
	async fn restart(&self, units: &[&str]) -> Result<(), UnitError> {
		todo!()
	}

	async fn stop(&self, units: &[&str]) -> Result<(), UnitError> {
		todo!()
	}

	async fn is_active(&self, unit: &str) -> Result<bool, UnitError> {
		todo!()
	}

	async fn start(&self, unit: &str) -> Result<(), UnitError> {
		todo!()
	}

	async fn result(&self, unit: &str) -> Result<String, UnitError> {
		todo!()
	}
}

/// The system's own `switch-to-configuration`, run as a child.
#[derive(Debug, Default)]
pub struct Process;

impl Switch for Process {
	async fn switch(&self, system: &StorePath) -> Result<(), SwitchError> {
		todo!()
	}
}

/// The machine's real clock.
#[derive(Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
	fn now(&self) -> i64 {
		todo!()
	}
}

/// Where a link points, `None` where there is no link.
pub fn read_link(link: &Path) -> io::Result<Option<String>> {
	todo!()
}

/// Sets a profile as `nix-env --set` does, a new `<profile>-<n>-link` beside it unless the last
/// already points there, then the profile's link renamed over to it.
pub fn set_profile(profile: &Path, target: &str) -> io::Result<()> {
	todo!()
}

/// Points `<root>/<name>` at `target` by a link made beside it and renamed over it.
pub fn link(root: &Path, name: &str, target: &str) -> io::Result<()> {
	todo!()
}

/// An exclusive lock on a file, held until dropped.
#[derive(Debug)]
pub struct Lock {
	file: std::fs::File,
}

/// Takes an exclusive lock on a file, creating it, waiting while another holds it.
pub fn lock(file: &Path) -> io::Result<Lock> {
	todo!()
}
