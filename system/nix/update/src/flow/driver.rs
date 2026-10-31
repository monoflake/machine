//! Taking a signed driver pointer and restoring links after a failed restart.

use super::*;
use crate::effects::Download;
use crate::{archive, pointer};

/// Fetches and installs a driver pointer, returning the shell's success or refusal code.
#[allow(clippy::too_many_arguments)]
pub async fn fetch_driver(
	bucket: &impl Bucket,
	download: &impl Download,
	units: &impl Units,
	config: &Config,
	paths: &Paths,
	clock: &impl Clock,
	secrets: &Secrets,
	dry: bool,
	out: &mut Output<'_>,
) -> i32 {
	let result = run(bucket, download, units, config, paths, clock, secrets, dry, out).await;
	finish(result, out)
}

#[allow(clippy::too_many_arguments)]
async fn run(
	bucket: &impl Bucket,
	download: &impl Download,
	units: &impl Units,
	config: &Config,
	paths: &Paths,
	clock: &impl Clock,
	secrets: &Secrets,
	dry: bool,
	out: &mut Output<'_>,
) -> Result<(), Refusal> {
	if !config.driver_channel {
		return Err(Refusal::DriverChannel);
	}
	let _lock = if dry {
		None
	} else {
		Some(host::lock(&paths.driver.join(".update-lock")).map_err(|_| Refusal::DriverRestart)?)
	};
	let Some(bytes) = incoming(bucket, config, true, out).await? else {
		return Ok(());
	};
	let pointer = pointer::driver(&bytes, &config.machine, clock.now(), config.driver_builds)?;
	if let Some(accepted) = state::read(&paths.accepted()).map_err(|_| Refusal::State)? {
		let previous =
			pointer::driver(&accepted, &config.machine, clock.now(), true).map_err(|_| Refusal::State)?;
		if pointer.at < previous.at {
			return Err(Refusal::Older);
		}
		if pointer.at == previous.at {
			if pointer.run != previous.run {
				return Err(Refusal::OtherRun);
			}
			let json = |bytes: &[u8]| {
				serde_json::from_slice::<serde_json::Value>(bytes).map_err(|_| Refusal::State)
			};
			if json(&bytes)? != json(&accepted)? {
				return Err(Refusal::ChangedPointer);
			}
			out.say(Step::AlreadyTaken);
			return Ok(());
		}
	}
	out.say(Step::ReadingRunningDriver);
	let current = link(&paths.driver, "current");
	if current.as_deref().and_then(|path| path.rsplit('/').next()) == Some(&pointer.version) {
		out.say(Step::RunningDriver);
		if !dry {
			record(paths, &bytes, out).map_err(|_| Refusal::State)?;
		}
		return Ok(());
	}
	if dry {
		out.say(Step::WouldInstall);
		return Ok(());
	}
	let archive = pointer.archive(&config.architecture).ok_or(Refusal::DriverFields)?;
	out.say(Step::DownloadingArchive);
	let contents = if archive.url.starts_with("build/driver/") {
		bucket.get(&archive.url).await.map_err(|_| Refusal::Download)?.ok_or(Refusal::Download)?
	} else {
		download.download(&archive.url).await.map_err(|_| Refusal::Download)?
	};
	out.say(Step::CheckingArchive);
	if archive::sha256(&contents) != archive.sha256 {
		return Err(Refusal::ArchiveHash);
	}
	out.say(Step::UnpackingArchive);
	let temporary = Temporary::beside(&paths.driver).map_err(|_| Refusal::ArchiveBinary)?;
	// Dropping the caller's directory also removes any files unpack left before refusing.
	archive::unpack(&contents, &temporary.0)?;
	let previous = link(&paths.driver, "previous");
	let installed = paths.driver.join(&pointer.version);
	if installed.is_dir() {
		fs::remove_dir_all(&installed).map_err(|_| Refusal::ArchiveBinary)?;
	}
	fs::rename(&temporary.0, installed).map_err(|_| Refusal::ArchiveBinary)?;
	out.say(Step::SwitchingLinks);
	host::link(&paths.driver, "current", &pointer.version).map_err(|_| Refusal::DriverRestart)?;
	if let Some(current) = &current {
		host::link(&paths.driver, "previous", current).map_err(|_| Refusal::DriverRestart)?;
	}
	out.say(Step::RestartingDriver);
	if let Err(error) = restart(units).await {
		out.masked(&error.to_string(), secrets);
		out.say(Step::RestoringDriver);
		if let Some(current) = &current {
			host::link(&paths.driver, "current", current).map_err(|_| Refusal::DriverRestore)?;
			match &previous {
				Some(previous) => host::link(&paths.driver, "previous", previous),
				None => remove_link(&paths.driver, "previous"),
			}
			.map_err(|_| Refusal::DriverRestore)?;
			restart(units).await.map_err(|_| Refusal::DriverRestore)?;
		} else {
			remove_link(&paths.driver, "current").map_err(|_| Refusal::DriverRestore)?;
			remove_link(&paths.driver, "previous").map_err(|_| Refusal::DriverRestore)?;
			let _ = units.stop(SERVICES).await;
		}
		return Err(Refusal::DriverRestart);
	}
	record(paths, &bytes, out).map_err(|_| Refusal::State)?;
	out.say(Step::RemovingOlder);
	for entry in fs::read_dir(&paths.driver).map_err(|_| Refusal::DriverRestart)? {
		let entry = entry.map_err(|_| Refusal::DriverRestart)?;
		if !entry.file_type().map_err(|_| Refusal::DriverRestart)?.is_dir() {
			continue;
		}
		let name = entry.file_name();
		let keep_previous = current.as_deref().and_then(|path| path.rsplit('/').next());
		if name == pointer.version.as_str() || keep_previous.is_some_and(|previous| name == previous) {
			continue;
		}
		fs::remove_dir_all(entry.path()).map_err(|_| Refusal::DriverRestart)?;
	}
	out.say(Step::InstallSucceeded);
	Ok(())
}
