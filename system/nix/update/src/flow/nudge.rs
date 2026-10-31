//! The restricted SSH command and its readable result.

use super::*;

/// Starts exactly the requested update instance and reports any readable result and link.
pub async fn nudge(command: &str, units: &impl Units, paths: &Paths, out: &mut Output<'_>) -> i32 {
	let path = match command {
		"system" => paths.current_system.clone(),
		"driver" => paths.driver.join("current"),
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

fn quoted(command: &str) -> String {
	if command.is_empty() {
		return "''".into();
	}
	if command.chars().any(char::is_control) {
		let mut text = String::from("$'");
		for c in command.chars() {
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
				c if c.is_control() => text.push_str(&format!("\\{:03o}", u32::from(c))),
				c => text.push(c),
			}
		}
		text.push('\'');
		text
	} else {
		let mut text = String::new();
		for c in command.chars() {
			if c.is_ascii() && !(c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c)) {
				text.push('\\');
			}
			text.push(c);
		}
		text
	}
}
