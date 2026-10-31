//! The restricted SSH command and its readable result.

use super::*;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;

/// Starts exactly the requested update instance and reports any readable result and link.
pub async fn nudge(
	command: impl AsRef<OsStr>,
	units: &impl Units,
	paths: &Paths,
	out: &mut Output<'_>,
) -> i32 {
	let command = command.as_ref();
	let (command, path) = match command.to_str() {
		Some("system") => ("system", paths.current_system.clone()),
		Some("driver") => ("driver", paths.driver.join("current")),
		_ => {
			out.error(&format!("nudge: refused {}", quoted(command)));
			return 1;
		}
	};
	let unit = format!("update-now@{command}.service");
	let status = if units.start(&unit).await.is_ok() { 0 } else { 1 };
	if let Ok(result) = units.result(&unit).await {
		out.line(&result);
	}
	if let Ok(Some(target)) = host::read_link(&path) {
		out.line(&target);
	}
	status
}

fn quoted(command: &OsStr) -> String {
	if command.is_empty() {
		return "''".into();
	}
	if command.to_str().is_none_or(|text| text.chars().any(char::is_control)) {
		let mut text = String::from("$'");
		for chunk in command.as_bytes().utf8_chunks() {
			for c in chunk.valid().chars() {
				match c {
					'\u{7}' => text.push_str("\\a"),
					'\u{8}' => text.push_str("\\b"),
					'\u{1b}' => text.push_str("\\E"),
					'\u{c}' => text.push_str("\\f"),
					'\n' => text.push_str("\\n"),
					'\r' => text.push_str("\\r"),
					'\t' => text.push_str("\\t"),
					'\u{b}' => text.push_str("\\v"),
					'\\' => text.push_str("\\\\"),
					'\'' => text.push_str("\\'"),
					c if c.is_control() => {
						for byte in c.encode_utf8(&mut [0; 4]).bytes() {
							text.push_str(&format!("\\{byte:03o}"));
						}
					}
					c => text.push(c),
				}
			}
			for byte in chunk.invalid() {
				text.push_str(&format!("\\{byte:03o}"));
			}
		}
		text.push('\'');
		text
	} else {
		let mut text = String::new();
		let mut previous = None;
		for c in command.to_string_lossy().chars() {
			let escape = match c {
				'#' => previous.is_none(),
				'~' => previous.is_none() || matches!(previous, Some(':' | '=')),
				c => c.is_ascii() && !(c.is_ascii_alphanumeric() || "_@%+=:./-".contains(c)),
			};
			if escape {
				text.push('\\');
			}
			text.push(c);
			previous = Some(c);
		}
		text
	}
}
