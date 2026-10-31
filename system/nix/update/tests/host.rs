//! The host lane's effects against temp directories and a fake switch, and the pure parts of the
//! D-Bus code without a bus.

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;

use futures_util::{StreamExt, stream};
use harmonia_store_path::{StoreDir, StorePath};
use machine_update::effects::{Clock, Switch, UnitError};
use machine_update::host::{
	Jobs, Process, Removed, SystemClock, is_active_state, link, lock, read_link, run_merged,
	set_profile, subscription, wait_removed,
};

const SYSTEM: &str = "55xkmqns51sw7nrgykp5vnz36w4fr3cw-nixos-system";

fn removed(job: &str, result: &str) -> Removed {
	Removed { job: job.to_owned(), result: result.to_owned() }
}

fn jobs(pairs: &[(&str, &str)]) -> Jobs {
	let mut jobs = Jobs::default();
	for (job, unit) in pairs {
		jobs.add(job, unit);
	}
	jobs
}

#[allow(clippy::unwrap_used)]
fn fake_system(store: &Path, script: &str) -> StorePath {
	let bin = store.join(SYSTEM).join("bin");
	fs::create_dir_all(&bin).unwrap();
	let program = bin.join("switch-to-configuration");
	fs::write(&program, script).unwrap();
	fs::set_permissions(&program, fs::Permissions::from_mode(0o755)).unwrap();
	StorePath::from_base_path(SYSTEM).unwrap()
}

#[tokio::test]
async fn jobs_all_done_ends_ok() {
	let removals = stream::iter(vec![removed("/j/2", "done"), removed("/j/1", "done")]);
	let waiting = jobs(&[("/j/1", "a.service"), ("/j/2", "b.service")]);
	wait_removed(removals, waiting, Some(Duration::from_secs(1))).await.unwrap();
}

#[tokio::test]
async fn jobs_not_asked_for_are_passed_over() {
	let removals = stream::iter(vec![removed("/j/9", "failed"), removed("/j/1", "done")]);
	wait_removed(removals, jobs(&[("/j/1", "a.service")]), None).await.unwrap();
}

#[tokio::test]
async fn job_not_done_names_its_unit() {
	let removals = stream::iter(vec![removed("/j/1", "done"), removed("/j/2", "failed")]);
	let waiting = jobs(&[("/j/1", "a.service"), ("/j/2", "b.service")]);
	let error = wait_removed(removals, waiting, None).await.unwrap_err();
	assert!(
		matches!(&error, UnitError::Job { unit, result } if unit == "b.service" && result == "failed"),
		"{error:?}"
	);
}

#[tokio::test]
async fn jobs_left_waiting_time_out() {
	let removals = stream::iter(vec![removed("/j/1", "done")]).chain(stream::pending());
	let waiting = jobs(&[("/j/1", "a.service"), ("/j/2", "b.service")]);
	let error = wait_removed(removals, waiting, Some(Duration::from_millis(50))).await.unwrap_err();
	assert!(matches!(error, UnitError::Timeout), "{error:?}");
}

#[tokio::test]
async fn ended_stream_is_a_bus_error() {
	let removals = stream::iter(Vec::<Removed>::new());
	let error = wait_removed(removals, jobs(&[("/j/1", "a.service")]), None).await.unwrap_err();
	assert!(matches!(error, UnitError::Bus(_)), "{error:?}");
}

#[test]
fn systemctl_active_states_are_active() {
	for state in ["active", "reloading", "refreshing"] {
		assert!(is_active_state(state), "systemctl accepts {state}");
	}
	for state in ["inactive", "activating", "deactivating", "failed"] {
		assert!(!is_active_state(state), "{state}");
	}
}

#[tokio::test]
async fn switch_merges_output_and_succeeds() {
	let store = tempfile::tempdir().unwrap();
	let system =
		fake_system(store.path(), "#!/bin/sh\necho \"out $1\"\necho err >&2\necho out2\nexit 0\n");
	let process = Process::in_store(StoreDir::new(store.path()).unwrap());
	process.switch(&system).await.unwrap();
	let program = store.path().join(SYSTEM).join("bin/switch-to-configuration");
	let (output, success) = run_merged(&program, "switch").await.unwrap();
	assert!(success);
	assert_eq!(output, "out switch\nerr\nout2\n", "successful switches must retain merged output");
}

#[tokio::test]
async fn switch_failure_carries_interleaved_output() {
	let store = tempfile::tempdir().unwrap();
	let system = fake_system(store.path(), "#!/bin/sh\necho one\necho two >&2\necho three\nexit 1\n");
	let process = Process::in_store(StoreDir::new(store.path()).unwrap());
	let error = process.switch(&system).await.unwrap_err();
	assert_eq!(error.output, "one\ntwo\nthree\n");
}

#[tokio::test]
async fn switch_runs_with_the_switch_argument() {
	let store = tempfile::tempdir().unwrap();
	let system = fake_system(store.path(), "#!/bin/sh\necho \"$# $1\"\nexit 1\n");
	let process = Process::in_store(StoreDir::new(store.path()).unwrap());
	assert_eq!(process.switch(&system).await.unwrap_err().output, "1 switch\n");
}

#[tokio::test]
async fn switch_of_a_missing_program_fails() {
	let store = tempfile::tempdir().unwrap();
	let system = StorePath::from_base_path(SYSTEM).unwrap();
	let process = Process::in_store(StoreDir::new(store.path()).unwrap());
	process.switch(&system).await.unwrap_err();
}

#[test]
fn clock_reads_unix_seconds() {
	let now = SystemClock.now();
	assert!(now > 1_700_000_000, "{now}");
}

#[test]
fn read_link_gives_the_target() {
	let dir = tempfile::tempdir().unwrap();
	symlink("1.0", dir.path().join("current")).unwrap();
	assert_eq!(read_link(&dir.path().join("current")).unwrap().as_deref(), Some("1.0"));
}

#[test]
fn read_link_of_nothing_is_none() {
	let dir = tempfile::tempdir().unwrap();
	assert_eq!(read_link(&dir.path().join("absent")).unwrap(), None);
	assert_eq!(read_link(&dir.path().join("absent/deeper")).unwrap(), None);
}

#[test]
fn read_link_of_a_file_or_directory_is_none() {
	let dir = tempfile::tempdir().unwrap();
	fs::write(dir.path().join("file"), "x").unwrap();
	assert_eq!(read_link(&dir.path().join("file")).unwrap(), None);
	assert_eq!(read_link(dir.path()).unwrap(), None);
	assert_eq!(read_link(&dir.path().join("file/under")).unwrap(), None);
}

#[test]
fn set_profile_makes_the_first_generation() {
	let dir = tempfile::tempdir().unwrap();
	let profile = dir.path().join("system");
	set_profile(&profile, "/nix/store/a-system").unwrap();
	assert_eq!(
		read_link(&dir.path().join("system-1-link")).unwrap().as_deref(),
		Some("/nix/store/a-system")
	);
	assert_eq!(read_link(&profile).unwrap().as_deref(), Some("system-1-link"));
}

#[test]
fn set_profile_adds_a_generation_for_a_new_target() {
	let dir = tempfile::tempdir().unwrap();
	let profile = dir.path().join("system");
	set_profile(&profile, "/nix/store/a").unwrap();
	set_profile(&profile, "/nix/store/b").unwrap();
	assert_eq!(
		read_link(&dir.path().join("system-2-link")).unwrap().as_deref(),
		Some("/nix/store/b")
	);
	assert_eq!(
		read_link(&dir.path().join("system-1-link")).unwrap().as_deref(),
		Some("/nix/store/a")
	);
	assert_eq!(read_link(&profile).unwrap().as_deref(), Some("system-2-link"));
}

#[test]
fn set_profile_to_the_same_target_reuses_the_generation() {
	let dir = tempfile::tempdir().unwrap();
	let profile = dir.path().join("system");
	set_profile(&profile, "/nix/store/a").unwrap();
	set_profile(&profile, "/nix/store/a").unwrap();
	assert!(!dir.path().join("system-2-link").exists());
	assert_eq!(read_link(&profile).unwrap().as_deref(), Some("system-1-link"));
}

#[test]
fn set_profile_continues_after_the_highest_generation() {
	let dir = tempfile::tempdir().unwrap();
	symlink("/nix/store/old", dir.path().join("system-3-link")).unwrap();
	symlink("/nix/store/older", dir.path().join("system-12-link")).unwrap();
	symlink("/nix/store/other", dir.path().join("other-40-link")).unwrap();
	let profile = dir.path().join("system");
	set_profile(&profile, "/nix/store/new").unwrap();
	assert_eq!(
		read_link(&dir.path().join("system-13-link")).unwrap().as_deref(),
		Some("/nix/store/new")
	);
	assert_eq!(read_link(&profile).unwrap().as_deref(), Some("system-13-link"));
}

#[test]
fn set_profile_returning_to_an_older_target_makes_a_new_generation() {
	let dir = tempfile::tempdir().unwrap();
	let profile = dir.path().join("system");
	set_profile(&profile, "/nix/store/a").unwrap();
	set_profile(&profile, "/nix/store/b").unwrap();
	set_profile(&profile, "/nix/store/a").unwrap();
	assert_eq!(
		read_link(&dir.path().join("system-3-link")).unwrap().as_deref(),
		Some("/nix/store/a")
	);
	assert_eq!(read_link(&profile).unwrap().as_deref(), Some("system-3-link"));
}

#[test]
fn set_profile_leaves_no_staging_links() {
	let dir = tempfile::tempdir().unwrap();
	set_profile(&dir.path().join("system"), "/nix/store/a").unwrap();
	let mut names: Vec<_> = fs::read_dir(dir.path())
		.unwrap()
		.map(|entry| entry.unwrap().file_name().into_string().unwrap())
		.collect();
	names.sort();
	assert_eq!(names, ["system", "system-1-link", "system.lock"]);
}

#[test]
fn link_makes_and_replaces() {
	let dir = tempfile::tempdir().unwrap();
	link(dir.path(), "current", "1.0").unwrap();
	assert_eq!(read_link(&dir.path().join("current")).unwrap().as_deref(), Some("1.0"));
	link(dir.path(), "current", "2.0").unwrap();
	assert_eq!(read_link(&dir.path().join("current")).unwrap().as_deref(), Some("2.0"));
	assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
}

#[test]
fn link_replaces_a_link_to_a_directory_without_following_it() {
	let dir = tempfile::tempdir().unwrap();
	let release = dir.path().join("release");
	fs::create_dir(&release).unwrap();
	symlink("release", dir.path().join("current")).unwrap();
	link(dir.path(), "current", "other").unwrap();
	assert_eq!(read_link(&dir.path().join("current")).unwrap().as_deref(), Some("other"));
	assert_eq!(fs::read_dir(&release).unwrap().count(), 0);
}

#[test]
fn lock_creates_the_file_and_can_be_retaken_after_drop() {
	let dir = tempfile::tempdir().unwrap();
	let file = dir.path().join("lock");
	drop(lock(&file).unwrap());
	assert!(file.exists());
	drop(lock(&file).unwrap());
}

#[test]
fn lock_waits_while_another_holds_it() {
	let dir = tempfile::tempdir().unwrap();
	let file = dir.path().join("lock");
	let held = lock(&file).unwrap();
	let (sender, receiver) = mpsc::channel();
	let path = file.clone();
	let waiter = std::thread::spawn(move || {
		let _taken = lock(&path).unwrap();
		sender.send(()).unwrap();
	});
	assert!(receiver.recv_timeout(Duration::from_millis(300)).is_err());
	drop(held);
	receiver.recv_timeout(Duration::from_secs(5)).unwrap();
	waiter.join().unwrap();
}

#[test]
fn repeated_subscription_is_success() {
	assert!(subscription(Ok(())).is_ok());
	let error = |name: &str| {
		zbus::Error::MethodError(
			name.try_into().unwrap(),
			None,
			zbus::Message::method_call("/", "Subscribe").build(&()).unwrap(),
		)
	};
	assert!(
		subscription(Err(error("org.freedesktop.systemd1.AlreadySubscribed"))).is_ok(),
		"restore uses the same connection"
	);
	assert!(subscription(Err(error("org.freedesktop.DBus.Error.AccessDenied"))).is_err());
}

#[tokio::test]
async fn skipped_job_succeeds() {
	wait_removed(stream::iter([removed("/j/1", "skipped")]), jobs(&[("/j/1", "a.service")]), None)
		.await
		.expect("systemctl accepts skipped jobs");
}

#[tokio::test]
async fn switch_does_not_wait_for_descendants_output() {
	let store = tempfile::tempdir().unwrap();
	let system = fake_system(store.path(), "#!/bin/sh\nsleep 2 &\necho parent\nexit 1\n");
	let process = Process::in_store(StoreDir::new(store.path()).unwrap());
	let error = tokio::time::timeout(Duration::from_secs(1), process.switch(&system))
		.await
		.expect("an inherited output descriptor must not delay process exit")
		.unwrap_err();
	assert_eq!(error.output, "parent\n");
}

#[test]
fn set_profile_waits_for_its_generation_lock() {
	let dir = tempfile::tempdir().unwrap();
	let profile = dir.path().join("system");
	let held = lock(&dir.path().join("system.lock")).unwrap();
	let (sender, receiver) = mpsc::channel();
	let waiter = std::thread::spawn(move || {
		set_profile(&profile, "/nix/store/new").unwrap();
		sender.send(()).unwrap();
	});
	let blocked = receiver.recv_timeout(Duration::from_millis(300)).is_err();
	assert!(
		!dir.path().join("system-1-link").exists(),
		"generation selection must wait for nix-env's lock"
	);
	drop(held);
	waiter.join().unwrap();
	assert!(blocked, "set_profile must hold the profile lock");
}
