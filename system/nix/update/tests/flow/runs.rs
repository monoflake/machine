//! The system update's runs as TLC makes them, model/protocol/update-runs.json, each replayed with
//! every effect logged in one sequence, the profile and the record where renamed over, RFC w0w82.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use harmonia_store_path::StorePath;
use machine_update::effects::{Boot, Freeze, Store, StoreError, Switch, SwitchError};
use machine_update::output::Output;
use machine_update::{flow, host};
use serde::Deserialize;

use super::support::*;

#[derive(Deserialize)]
struct Runs {
	runs: Vec<Run>,
}

#[derive(Deserialize)]
struct Run {
	case: Case,
	steps: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct Case {
	pointer: String,
	running: bool,
	taken: bool,
	realise: String,
	switch: String,
	freeze: String,
	sync: String,
}

/// The run's effects in the order they came.
struct Log {
	entries: RefCell<Vec<String>>,
	profile: PathBuf,
	accepted: PathBuf,
	seen: RefCell<(Option<u64>, Option<u64>)>,
}

impl Log {
	fn new(f: &Fixture) -> Self {
		let log = Self {
			entries: RefCell::default(),
			profile: f.paths.profile.clone(),
			accepted: f.paths.accepted(),
			seen: RefCell::default(),
		};
		*log.seen.borrow_mut() = log.look();
		log
	}

	/// The inode of the profile's link and of the record, each new where it was renamed over.
	fn look(&self) -> (Option<u64>, Option<u64>) {
		let inode = |path: &Path| fs::symlink_metadata(path).ok().map(|meta| meta.ino());
		(inode(&self.profile), inode(&self.accepted))
	}

	/// Notes the profile or the record where either was written since the last effect, then it.
	fn note(&self, effect: Option<&str>) {
		let now = self.look();
		let mut seen = self.seen.borrow_mut();
		let mut entries = self.entries.borrow_mut();
		if now.0 != seen.0 {
			entries.push("profile".into());
		}
		if now.1 != seen.1 {
			entries.push("record".into());
		}
		*seen = now;
		entries.extend(effect.map(str::to_owned));
	}
}

struct Realiser<'a> {
	log: &'a Log,
	fails: bool,
}

impl Store for Realiser<'_> {
	async fn realise(&mut self, _: &StorePath) -> Result<(), StoreError> {
		self.log.note(Some("realise"));
		if self.fails { Err(StoreError { lines: vec!["realise failed".into()] }) } else { Ok(()) }
	}
}

struct Switcher<'a> {
	log: &'a Log,
	current: PathBuf,
	failures: RefCell<VecDeque<bool>>,
}

impl Switch for Switcher<'_> {
	async fn switch(&self, system: &StorePath) -> Result<(), SwitchError> {
		self.log.note(Some("switch"));
		if self.failures.borrow_mut().pop_front().unwrap_or(false) {
			return Err(SwitchError { output: "switch failed".into() });
		}
		let root = self.current.parent().unwrap();
		host::link(root, "current-system", &format!("/nix/store/{system}")).unwrap();
		Ok(())
	}
}

struct Rester<'a> {
	log: &'a Log,
	answer: &'a str,
	sync_fails: bool,
}

impl Boot for Rester<'_> {
	fn freeze(&self) -> io::Result<Freeze> {
		self.log.note(Some("freeze"));
		match self.answer {
			"unsupported" => Ok(Freeze::Unsupported("vfat".into())),
			"unmounted" => Ok(Freeze::NotMounted),
			"failed" => Err(io::Error::from(io::ErrorKind::PermissionDenied)),
			_ => Ok(Freeze::Held),
		}
	}

	fn thaw(&self) -> io::Result<()> {
		self.log.note(Some("thaw"));
		Ok(())
	}

	fn sync(&self) -> io::Result<()> {
		self.log.note(Some("sync"));
		if self.sync_fails { Err(io::Error::from(io::ErrorKind::TimedOut)) } else { Ok(()) }
	}
}

/// The steps the update takes on the machine a case describes.
async fn replay(case: &Case) -> Vec<String> {
	let f = Fixture::new(false);
	if case.pointer == "present" {
		f.signed(&f.system_pointer(0, "1"));
	}
	if case.running {
		host::link(f.paths.current_system.parent().unwrap(), "current-system", NEW).unwrap();
		host::set_profile(&f.paths.profile, NEW).unwrap();
	}
	if case.taken {
		let pointer = f.bucket.objects.borrow().get(&f.key()).unwrap().clone();
		fs::write(f.paths.accepted(), pointer).unwrap();
	}
	let log = Log::new(&f);
	let mut store = Realiser { log: &log, fails: case.realise == "fails" };
	let switch = Switcher {
		log: &log,
		current: f.paths.current_system.clone(),
		failures: RefCell::new(VecDeque::from([case.switch == "fails"])),
	};
	let boot = Rester { log: &log, answer: &case.freeze, sync_fails: case.sync == "fails" };
	let capture = Capture::default();
	let mut stdout = capture.clone();
	let mut stderr = capture.clone();
	let mut out = Output::new(&mut stdout, &mut stderr);
	let (_, secrets) = flow::access(&f.config, Some(&f.config.credentials_file), &mut out).unwrap();
	let paths = &f.paths;
	flow::fetch_system(
		&f.bucket, &mut store, &switch, &boot, &f.config, paths, &ClockFake, &secrets, false, &mut out,
	)
	.await;
	log.note(None);
	log.entries.take()
}

#[tokio::test(start_paused = true)]
async fn each_run_tlc_makes_takes_its_steps_in_their_order() {
	let fixture = include_str!("../../../../../model/protocol/update-runs.json");
	let fixture: Runs = serde_json::from_str(fixture).unwrap();
	assert!(fixture.runs.len() > 1);
	for run in &fixture.runs {
		assert_eq!(replay(&run.case).await, run.steps, "{:?}", run.case);
	}
}
