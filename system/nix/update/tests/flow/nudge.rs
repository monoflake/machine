//! Exact commands and bash quoting use the recorded nudge samples.

use std::fs;

use machine_update::flow;
use machine_update::output::Output;
use serde_json::{Value, json};

use super::support::*;

#[tokio::test(start_paused = true)]
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

#[tokio::test(start_paused = true)]
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

#[test]
fn binary_refusal_matches_bash_5_quoting_rules() {
	use std::os::unix::ffi::OsStrExt;
	let cases: &[(&[u8], &[u8])] = &[
		(b"\x01", b"$'\\001'"),
		(b"\x02", b"$'\\002'"),
		(b"\x03", b"$'\\003'"),
		(b"\x04", b"$'\\004'"),
		(b"\x05", b"$'\\005'"),
		(b"\x06", b"$'\\006'"),
		(b"\x07", b"$'\\a'"),
		(b"\x08", b"$'\\b'"),
		(b"\x09", b"$'\\t'"),
		(b"\x0a", b"$'\\n'"),
		(b"\x0b", b"$'\\v'"),
		(b"\x0c", b"$'\\f'"),
		(b"\x0d", b"$'\\r'"),
		(b"\x0e", b"$'\\016'"),
		(b"\x0f", b"$'\\017'"),
		(b"\x10", b"$'\\020'"),
		(b"\x11", b"$'\\021'"),
		(b"\x12", b"$'\\022'"),
		(b"\x13", b"$'\\023'"),
		(b"\x14", b"$'\\024'"),
		(b"\x15", b"$'\\025'"),
		(b"\x16", b"$'\\026'"),
		(b"\x17", b"$'\\027'"),
		(b"\x18", b"$'\\030'"),
		(b"\x19", b"$'\\031'"),
		(b"\x1a", b"$'\\032'"),
		(b"\x1b", b"$'\\E'"),
		(b"\x1c", b"$'\\034'"),
		(b"\x1d", b"$'\\035'"),
		(b"\x1e", b"$'\\036'"),
		(b"\x1f", b"$'\\037'"),
		(b" ", b"\\ "),
		(b"!", b"\\!"),
		(b"\"", b"\\\""),
		(b"#", b"\\#"),
		(b"$", b"\\$"),
		(b"%", b"%"),
		(b"&", b"\\&"),
		(b"'", b"\\'"),
		(b"(", b"\\("),
		(b")", b"\\)"),
		(b"*", b"\\*"),
		(b"+", b"+"),
		(b",", b"\\,"),
		(b"-", b"-"),
		(b".", b"."),
		(b"/", b"/"),
		(b"0", b"0"),
		(b"1", b"1"),
		(b"2", b"2"),
		(b"3", b"3"),
		(b"4", b"4"),
		(b"5", b"5"),
		(b"6", b"6"),
		(b"7", b"7"),
		(b"8", b"8"),
		(b"9", b"9"),
		(b":", b":"),
		(b";", b"\\;"),
		(b"<", b"\\<"),
		(b"=", b"="),
		(b">", b"\\>"),
		(b"?", b"\\?"),
		(b"@", b"@"),
		(b"A", b"A"),
		(b"B", b"B"),
		(b"C", b"C"),
		(b"D", b"D"),
		(b"E", b"E"),
		(b"F", b"F"),
		(b"G", b"G"),
		(b"H", b"H"),
		(b"I", b"I"),
		(b"J", b"J"),
		(b"K", b"K"),
		(b"L", b"L"),
		(b"M", b"M"),
		(b"N", b"N"),
		(b"O", b"O"),
		(b"P", b"P"),
		(b"Q", b"Q"),
		(b"R", b"R"),
		(b"S", b"S"),
		(b"T", b"T"),
		(b"U", b"U"),
		(b"V", b"V"),
		(b"W", b"W"),
		(b"X", b"X"),
		(b"Y", b"Y"),
		(b"Z", b"Z"),
		(b"[", b"\\["),
		(b"\\", b"\\\\"),
		(b"]", b"\\]"),
		(b"^", b"\\^"),
		(b"_", b"_"),
		(b"`", b"\\`"),
		(b"a", b"a"),
		(b"b", b"b"),
		(b"c", b"c"),
		(b"d", b"d"),
		(b"e", b"e"),
		(b"f", b"f"),
		(b"g", b"g"),
		(b"h", b"h"),
		(b"i", b"i"),
		(b"j", b"j"),
		(b"k", b"k"),
		(b"l", b"l"),
		(b"m", b"m"),
		(b"n", b"n"),
		(b"o", b"o"),
		(b"p", b"p"),
		(b"q", b"q"),
		(b"r", b"r"),
		(b"s", b"s"),
		(b"t", b"t"),
		(b"u", b"u"),
		(b"v", b"v"),
		(b"w", b"w"),
		(b"x", b"x"),
		(b"y", b"y"),
		(b"z", b"z"),
		(b"{", b"\\{"),
		(b"|", b"\\|"),
		(b"}", b"\\}"),
		(b"~", b"\\~"),
		(b"\x7f", b"$'\\177'"),
		(b"a#b", b"a#b"),
		(b"x~y", b"x~y"),
		(b"a:~b", b"a:\\~b"),
		(b"a=~b", b"a=\\~b"),
		(b"#a", b"\\#a"),
		(b"~a", b"\\~a"),
		(b"a~:~b=~c", b"a~:\\~b=\\~c"),
		(b"", b"''"),
		(b"a\x0a'\\", b"$'a\\n\\'\\\\'"),
		(b"\xc3\xa9\xe9\x9b\xaa", b"\xc3\xa9\xe9\x9b\xaa"),
		(b"\xc2\x80\xc2\x85\xc2\x9f", b"$'\\302\\200\\302\\205\\302\\237'"),
	];
	for (command, quoted) in cases {
		let output = std::process::Command::new(env!("CARGO_BIN_EXE_machine-update-nudge"))
			.env("SSH_ORIGINAL_COMMAND", std::ffi::OsStr::from_bytes(command))
			.output()
			.unwrap();
		assert_eq!(output.status.code(), Some(1));
		assert!(output.stdout.is_empty());
		let expected = [b"nudge: refused ".as_slice(), quoted, b"\n"].concat();
		assert_eq!(output.stderr, expected, "refusal must preserve bash quoting for {command:?}");
	}
}

#[test]
fn binary_refuses_non_utf8_command_from_its_bytes() {
	use std::os::unix::ffi::OsStrExt;
	let cases: &[(&[u8], &[u8])] = &[
		(b"\xff", b"$'\\377'"),
		(b"a\xffb", b"$'a\\377b'"),
		(b"\xc3", b"$'\\303'"),
		(b"\xc3\xa9\xff\x0a", b"$'\xc3\xa9\\377\\n'"),
		(b"\x80\xc0\xfe", b"$'\\200\\300\\376'"),
	];
	for (command, quoted) in cases {
		let output = std::process::Command::new(env!("CARGO_BIN_EXE_machine-update-nudge"))
			.env("SSH_ORIGINAL_COMMAND", std::ffi::OsStr::from_bytes(command))
			.output()
			.unwrap();
		assert_eq!(output.status.code(), Some(1));
		assert!(output.stdout.is_empty());
		assert_eq!(
			output.stderr,
			[b"nudge: refused ".as_slice(), quoted, b"\n"].concat(),
			"invalid UTF8 must not become an empty command"
		);
	}
}
