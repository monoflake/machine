//! The explicit driver rollback leaves accepted pointer state alone.

use std::os::unix::fs::PermissionsExt;

use super::*;

/// Swaps current and previous for root, restoring both links after a failed restart.
pub async fn rollback(units: &impl Units, paths: &Paths, root: bool, out: &mut Output<'_>) -> i32 {
	match run(units, paths, root, out).await {
		Ok(()) => 0,
		Err(message) => {
			out.error(&format!("update: {message}"));
			1
		}
	}
}

async fn run(
	units: &impl Units,
	paths: &Paths,
	root: bool,
	out: &mut Output<'_>,
) -> Result<(), &'static str> {
	if !root {
		return Err("rollback requires root");
	}
	let _lock =
		host::lock(&paths.driver.join(".update-lock")).map_err(|_| "current driver unavailable")?;
	let current = link(&paths.driver, "current").ok_or("current driver unavailable")?;
	let previous = link(&paths.driver, "previous").ok_or("previous driver unavailable")?;
	let binary = paths.driver.join(&previous).join("driver-machine");
	if !fs::metadata(binary).is_ok_and(|metadata| metadata.permissions().mode() & 0o111 != 0) {
		return Err("previous binary unavailable");
	}
	host::link(&paths.driver, "current", &previous).map_err(|_| "current driver unavailable")?;
	host::link(&paths.driver, "previous", &current).map_err(|_| "previous driver unavailable")?;
	if restart(units).await.is_err() {
		host::link(&paths.driver, "current", &current)
			.map_err(|_| "rollback restart failed, restored current link")?;
		host::link(&paths.driver, "previous", &previous)
			.map_err(|_| "rollback restart failed, restored current link")?;
		let _ = restart(units).await;
		return Err("rollback restart failed, restored current link");
	}
	out.line(&format!("update: rolled driver back to {previous}"));
	Ok(())
}
