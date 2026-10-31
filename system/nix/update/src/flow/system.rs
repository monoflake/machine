//! Taking a signed system pointer without building.

use harmonia_store_path::{StoreDir, StorePath};

use super::*;
use crate::effects::{Store, Switch};
use crate::pointer;

/// Fetches and takes a system pointer, printing each shell step and returning its exit code.
#[allow(clippy::too_many_arguments)]
pub async fn fetch_system(
	bucket: &impl Bucket,
	store: &mut impl Store,
	switch: &impl Switch,
	config: &Config,
	paths: &Paths,
	clock: &impl Clock,
	secrets: &Secrets,
	dry: bool,
	out: &mut Output<'_>,
) -> i32 {
	let result = run(bucket, store, switch, config, paths, clock, secrets, dry, out).await;
	finish(result, out)
}

#[allow(clippy::too_many_arguments)]
async fn run(
	bucket: &impl Bucket,
	store: &mut impl Store,
	switch: &impl Switch,
	config: &Config,
	paths: &Paths,
	clock: &impl Clock,
	secrets: &Secrets,
	dry: bool,
	out: &mut Output<'_>,
) -> Result<(), Refusal> {
	let bytes = incoming(bucket, config, false, out).await?.ok_or(Refusal::PointerFetch)?;
	let pointer = pointer::system(&bytes, &config.machine, clock.now())?;
	let mut taken = false;
	if let Some(accepted) = state::read(&paths.accepted()).map_err(|_| Refusal::State)? {
		let accepted =
			pointer::system(&accepted, &config.machine, clock.now()).map_err(|_| Refusal::State)?;
		if pointer.at < accepted.at {
			return Err(Refusal::Older);
		}
		if pointer.at == accepted.at {
			if pointer.run != accepted.run {
				return Err(Refusal::OtherRun);
			}
			if pointer.path != accepted.path {
				return Err(Refusal::ChangedPath);
			}
			taken = true;
			out.say(Step::AlreadyTaken);
		}
	}
	out.say(Step::ReadingRunningSystem);
	let current = host::read_link(&paths.current_system).ok().flatten().ok_or(Refusal::Running)?;
	if current == pointer.path {
		out.say(Step::RunningSystem);
		if !dry && !taken {
			record(paths, &bytes, out).map_err(|_| Refusal::State)?;
		}
		return Ok(());
	}
	out.say(Step::DiffersFromRunning);
	if taken {
		out.say(Step::WouldNotSwitchAgain);
		return Ok(());
	}
	if dry {
		out.say(Step::WouldSwitch);
		return Ok(());
	}
	out.say(Step::Realising);
	let system = StoreDir::default().parse::<StorePath>(&pointer.path).map_err(|error| {
		out.masked(&error.to_string(), secrets);
		Refusal::Realise
	})?;
	if let Err(error) = store.realise(&system).await {
		out.masked(&error.lines.join("\n"), secrets);
		return Err(Refusal::Realise);
	}
	out.say(Step::SettingProfile);
	host::set_profile(&paths.profile, &pointer.path).map_err(|_| Refusal::Profile)?;
	out.say(Step::Switching);
	if let Err(error) = switch.switch(&system).await {
		out.masked(&error.output, secrets);
		out.say(Step::RestoringSystem);
		host::set_profile(&paths.profile, &current).map_err(|_| Refusal::ProfileRestore)?;
		let previous =
			StoreDir::default().parse::<StorePath>(&current).map_err(|_| Refusal::SystemRestore)?;
		switch.switch(&previous).await.map_err(|_| Refusal::SystemRestore)?;
		return Err(Refusal::Switch);
	}
	record(paths, &bytes, out).map_err(|_| Refusal::State)?;
	out.say(Step::SwitchSucceeded);
	Ok(())
}
