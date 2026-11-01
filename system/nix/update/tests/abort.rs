//! A SIGABRT names the run's last step and still kills it by that signal, RFC cbtjl item 10.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::io::{BufRead, BufReader, Read};
use std::os::unix::process::ExitStatusExt;
use std::process::{Command, ExitStatus, Stdio};

use machine_update::output::{self, Step};
use rustix::process::{Pid, Signal, kill_process};

const CHILD: &str = "MACHINE_UPDATE_ABORT_CHILD";

fn died_by_abort(status: ExitStatus, stderr: &str, step: &str) {
	assert_eq!(status.signal(), Some(Signal::ABORT.as_raw()), "{status:?}");
	let line = format!("update: aborted by SIGABRT, last step {step}");
	assert!(stderr.lines().any(|found| found == line), "{stderr}");
}

// Does nothing but where `self_abort` runs this test binary again as its child.
#[test]
fn aborting_child() {
	let Ok(kind) = std::env::var(CHILD) else { return };
	machine_update_abort::install();
	if kind == "step" {
		output::say(Step::FetchingSystemPointer);
	}
	std::process::abort();
}

fn self_abort(kind: &str) -> (ExitStatus, String) {
	let output = Command::new(std::env::current_exe().unwrap())
		.args(["--exact", "aborting_child", "--nocapture"])
		.env(CHILD, kind)
		.output()
		.unwrap();
	(output.status, String::from_utf8_lossy(&output.stderr).into_owned())
}

#[test]
fn a_real_abort_names_the_last_step() {
	let (status, stderr) = self_abort("step");
	died_by_abort(status, &stderr, "fetching system pointer");
}

#[test]
fn an_abort_before_any_step_says_none() {
	let (status, stderr) = self_abort("none");
	died_by_abort(status, &stderr, "none");
}

// The endpoint file is a FIFO nobody writes, so the real program waits inside its first step.
#[test]
fn the_fetch_program_names_the_step_it_waits_in() {
	let directory = tempfile::tempdir().unwrap();
	let endpoint = directory.path().join("endpoint");
	assert!(Command::new("mkfifo").arg(&endpoint).status().unwrap().success());
	let config = directory.path().join("config.json");
	let fields = serde_json::json!({
		"bucket": "systems",
		"machine": "test",
		"credentialsFile": directory.path().join("credentials"),
		"endpointFile": endpoint,
		"signers": directory.path().join("signers"),
		"driverSigners": directory.path().join("driver-signers"),
		"driverChannel": false,
		"driverBuilds": false,
		"architecture": "x86_64-linux",
		"trusted": "",
	});
	std::fs::write(&config, fields.to_string()).unwrap();

	let mut child = Command::new(env!("CARGO_BIN_EXE_machine-update-fetch"))
		.args(["system", "--dry-run"])
		.env("MACHINE_UPDATE_CONFIG", &config)
		.env("STATE_DIRECTORY", directory.path())
		.stdout(Stdio::piped())
		.stderr(Stdio::piped())
		.spawn()
		.unwrap();
	let mut stdout = BufReader::new(child.stdout.take().unwrap());
	let mut line = String::new();
	stdout.read_line(&mut line).unwrap();
	assert_eq!(line, "update: reading runtime access files\n");

	kill_process(Pid::from_child(&child), Signal::ABORT).unwrap();
	let mut stderr = String::new();
	child.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
	died_by_abort(child.wait().unwrap(), &stderr, "reading runtime access files");
}
