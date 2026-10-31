//! Exact commands and bash quoting use the recorded nudge samples.

use std::fs;

use machine_update::flow;
use machine_update::output::Output;
use serde_json::{Value, json};

use super::support::*;

#[tokio::test]
async fn samples_match_stdout_stderr_units_and_normalized_start_status() {
	let sample: Value = serde_json::from_str(include_str!("../samples/nudge.json")).unwrap();
	let f = Fixture::new(false);
	machine_update::host::link(f.temporary.path(), "current-system", NEW).unwrap();
	std::os::unix::fs::symlink("1.0", f.paths.driver.join("current")).unwrap();
	let mut accepted = sample["accepted"].as_array().unwrap().clone();
	accepted.push(json!({"command":"driver", "unit":"update-now@driver.service", "failed":true, "stdout":["exit-code", "1.0"], "exit":1}));
	for case in &accepted {
		let units = UnitsFake::default();
		units.start_failed.set(case["failed"].as_bool().unwrap_or(false));
		let mut stdout = Vec::new();
		let mut stderr = Vec::new();
		let code = flow::nudge(
			case["command"].as_str().unwrap(),
			&units,
			&f.paths,
			&mut Output::new(&mut stdout, &mut stderr),
		)
		.await;
		assert_eq!(i64::from(code), case["exit"].as_i64().unwrap());
		let expected: Vec<String> =
			case["stdout"].as_array().unwrap().iter().map(|line| line.as_str().unwrap().into()).collect();
		assert_eq!(String::from_utf8(stdout).unwrap(), format!("{}\n", expected.join("\n")));
		assert!(stderr.is_empty());
		let unit = case["unit"].as_str().unwrap();
		assert_eq!(*units.calls.borrow(), [format!("start {unit}"), format!("result {unit}")]);
	}
	for case in sample["refused"].as_array().unwrap() {
		let units = UnitsFake::default();
		let mut stdout = Vec::new();
		let mut stderr = Vec::new();
		assert_eq!(
			flow::nudge(
				case["command"].as_str().unwrap(),
				&units,
				&f.paths,
				&mut Output::new(&mut stdout, &mut stderr)
			)
			.await,
			1
		);
		assert!(stdout.is_empty());
		assert!(units.calls.borrow().is_empty());
		assert_eq!(
			String::from_utf8(stderr).unwrap(),
			format!("{}\n", case["stderr"].as_str().unwrap())
		);
	}
}

#[tokio::test]
async fn unreadable_result_and_link_do_not_change_start_status() {
	let f = Fixture::new(false);
	let units = UnitsFake::default();

	for missing_link in [false, true] {
		if missing_link {
			fs::remove_file(&f.paths.current_system).unwrap();
		}
		for missing_result in [false, true] {
			units.result_failed.set(missing_result);
			for failed in [false, true] {
				units.start_failed.set(failed);
				let mut stdout = Vec::new();
				let mut stderr = Vec::new();
				assert_eq!(
					flow::nudge("system", &units, &f.paths, &mut Output::new(&mut stdout, &mut stderr)).await,
					i32::from(failed)
				);
				let mut expected = String::new();
				if !missing_result {
					expected.push_str(if failed { "exit-code\n" } else { "success\n" });
				}
				if !missing_link {
					expected.push_str(OLD);
					expected.push('\n');
				}
				assert_eq!(stdout, expected.as_bytes());
				assert!(stderr.is_empty());
			}
		}
	}
}

#[test]
fn unset_command_binary_refuses_without_a_bus() {
	let output = std::process::Command::new(env!("CARGO_BIN_EXE_machine-update-nudge"))
		.env_remove("SSH_ORIGINAL_COMMAND")
		.output()
		.unwrap();
	assert_eq!(output.status.code(), Some(1));
	assert!(output.stdout.is_empty());
	assert_eq!(output.stderr, b"nudge: refused ''\n");
}
