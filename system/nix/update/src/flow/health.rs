//! A driver update judged by the driver's own program, which alone knows its protocol, RFC okz12.

use std::time::Duration;

use super::*;
use crate::effects::{Program, Ran, Units};

/// How long the version being replaced has to write what stands.
const SNAPSHOT_LIMIT: Duration = Duration::from_secs(30);

/// How long the new version has to judge itself, past its own bounds of 170 s together.
const CHECK_LIMIT: Duration = Duration::from_secs(180);

/// The exit of a command a version does not know, clap's for any usage error.
const USAGE: i32 = 2;

/// Seconds both services must stay active where the updater reads level 1 itself, the check's own.
const SETTLE: u32 = 20;

/// What a judgement ended as.
pub(super) enum Judged {
	/// The new version stands.
	Passed,
	/// It does not, and why, masked.
	Failed(String),
}

/// A baseline's file, removed however the run ends, and whether deployments stood uncompared.
pub(super) struct Baseline {
	file: Option<PathBuf>,
	uncompared: bool,
}

impl Baseline {
	const fn none(uncompared: bool) -> Self {
		Self { file: None, uncompared }
	}
}

impl Drop for Baseline {
	fn drop(&mut self) {
		if let Some(file) = &self.file {
			let _ = fs::remove_file(file);
		}
	}
}

fn binary(paths: &Paths) -> PathBuf {
	paths.driver.join("current/driver-machine")
}

/// The arguments of one of the driver's two commands, the file last.
fn arguments(command: &str, config: &Config, file: Option<&Path>) -> Vec<String> {
	let mut args = vec![command.to_owned()];
	args.extend(config.driver_health.iter().cloned());
	args.extend(file.map(|file| file.display().to_string()));
	args
}

/// The running version's baseline, none on a first install, from a version with no such command, or
/// where it failed, each said, level 3 then skipped rather than the update held back.
pub(super) async fn baseline(
	program: &impl Program,
	config: &Config,
	paths: &Paths,
	current: Option<&str>,
	secrets: &Secrets,
	out: &mut Output<'_>,
) -> Baseline {
	if current.is_none() {
		out.say(Step::FirstInstall);
		return Baseline::none(false);
	}
	let file = paths.snapshot();
	// One left by a run that died is never a baseline for this one.
	let _ = fs::remove_file(&file);
	out.say(Step::TakingSnapshot);
	let args = arguments("snapshot", config, Some(&file));
	match program.run(&binary(paths), &args, SNAPSHOT_LIMIT).await {
		Ran::Exited { code: Some(0), .. } => Baseline { file: Some(file), uncompared: false },
		Ran::Exited { code: Some(USAGE), .. } => {
			out.say(Step::NoSnapshotCommand);
			Baseline::none(true)
		}
		Ran::Exited { output, .. } | Ran::TimedOut { output } => {
			out.masked(&output, secrets);
			out.say(Step::SnapshotFailed);
			let _ = fs::remove_file(&file);
			Baseline::none(true)
		}
		Ran::Unstarted(why) => {
			out.masked(&why, secrets);
			out.say(Step::SnapshotFailed);
			Baseline::none(true)
		}
	}
}

/// The last line a program wrote, or what stands in for it.
fn last_line(output: &str, otherwise: &str) -> String {
	let last = output.lines().rev().find(|line| !line.trim().is_empty());
	last.unwrap_or(otherwise).to_owned()
}

/// A version's semver core, a suffix after `+` or `-` passed over, none where it has no such core.
fn core(version: &str) -> Option<[u64; 3]> {
	let bare = version.split(['+', '-']).next()?;
	let mut parts = bare.split('.').map(|part| part.parse::<u64>().ok());
	let core = [parts.next()??, parts.next()??, parts.next()??];
	parts.next().is_none().then_some(core)
}

/// Whether a target is a lower version than the one running, a name with no core never being so.
pub(super) fn older(target: &str, running: &str) -> bool {
	matches!((core(target), core(running)), (Some(target), Some(running)) if target < running)
}

/// Both services' identities, each only while it is active.
async fn identities(units: &impl Units) -> Result<[(u32, u32); 2], String> {
	let mut read = [(0, 0); 2];
	for (slot, unit) in read.iter_mut().zip(SERVICES) {
		if !units.is_active(unit).await.unwrap_or(false) {
			return Err(format!("{unit} is not active"));
		}
		*slot = units.identity(unit).await.map_err(|error| format!("{unit}, {error}"))?;
	}
	Ok(read)
}

/// Level 1 read by the updater, for a version too old to read it, the same process throughout.
async fn level_one(units: &impl Units) -> Result<(), String> {
	let first = identities(units).await?;
	for _ in 0..SETTLE {
		tokio::time::sleep(Duration::from_secs(1)).await;
		if identities(units).await? != first {
			return Err("a service restarted within the settle".to_owned());
		}
	}
	Ok(())
}

/// The new version's judgement of itself, a non-zero exit, a kill or no start each a failure, but
/// for a move to a lower version with no such command, which rings make on purpose.
#[allow(clippy::too_many_arguments)]
pub(super) async fn check(
	program: &impl Program,
	units: &impl Units,
	older: bool,
	config: &Config,
	paths: &Paths,
	baseline: &Baseline,
	secrets: &Secrets,
	out: &mut Output<'_>,
) -> Judged {
	out.say(Step::CheckingDriver);
	let args = arguments("check", config, baseline.file.as_deref());
	let (output, why) = match program.run(&binary(paths), &args, CHECK_LIMIT).await {
		Ran::Exited { code: Some(0), .. } => {
			out.say(if baseline.uncompared { Step::CheckPassedUncompared } else { Step::CheckPassed });
			return Judged::Passed;
		}
		Ran::Exited { code: Some(USAGE), .. } if older => {
			return match level_one(units).await {
				Ok(()) => {
					out.say(Step::OlderKept);
					Judged::Passed
				}
				Err(why) => Judged::Failed(secrets.mask(&format!("level 1, {why}"))),
			};
		}
		Ran::Exited { output, code } => {
			let otherwise = code.map_or("killed by a signal".to_owned(), |c| format!("exit {c}"));
			let why = last_line(&output, &otherwise);
			(output, why)
		}
		Ran::TimedOut { output } => {
			let limit = CHECK_LIMIT.as_secs();
			(output, format!("no result within {limit} s"))
		}
		Ran::Unstarted(why) => (why.clone(), format!("not started, {why}")),
	};
	out.masked(&output, secrets);
	Judged::Failed(secrets.mask(&why))
}
