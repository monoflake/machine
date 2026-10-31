//! A pointer's SSH signature, checked against an allowed signers file as `ssh-keygen -Y` did.
//! Written by the pointer lane.

use ssh_key::{PublicKey, SshSig};

/// The namespace a pointer is signed in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Namespace {
	/// `system-pointer`, signed by `ci` alone.
	System,
	/// `driver-pointer`, signed by `ci` or `mac`.
	Driver,
}

impl Namespace {
	fn name(self) -> &'static str {
		match self {
			Self::System => "system-pointer",
			Self::Driver => "driver-pointer",
		}
	}
}

/// Whether `signature` signs `message` in `namespace` by a principal the allowed signers file
/// lists for that namespace, `ci` in either and `mac` in `driver-pointer` alone.
pub fn verify(signers: &str, namespace: Namespace, message: &[u8], signature: &[u8]) -> bool {
	let Ok(signature) = SshSig::from_pem(signature) else {
		return false;
	};
	let name = namespace.name();
	signers.lines().filter_map(signer).any(|signer| {
		let allowed = match signer.principal.as_str() {
			"ci" => true,
			"mac" => namespace == Namespace::Driver,
			_ => false,
		};
		allowed
			&& signer.namespaces.as_ref().is_none_or(|list| list.iter().any(|item| item == name))
			&& signer.key.key_data() == signature.public_key()
			&& signer.key.verify(name, message, &signature).is_ok()
	})
}

/// One allowed signers line, its principals field whole.
struct Signer {
	principal: String,
	/// The `namespaces` option's literal names, `None` where the line sets none.
	namespaces: Option<Vec<String>>,
	key: PublicKey,
}

/// A line read as `principals [options] keytype base64 [comment]`, `None` for a blank, a comment,
/// a line with any option but `namespaces`, or a key that does not parse.
fn signer(line: &str) -> Option<Signer> {
	let line = line.trim();
	if line.is_empty() || line.starts_with('#') {
		return None;
	}
	let (principal, rest) = word(line)?;
	let principal = if let Some(quoted) = principal.strip_prefix('"') {
		quoted.strip_suffix('"')?.to_owned()
	} else {
		principal
	};
	let (second, after) = word(rest)?;
	let (namespaces, key_type, after) = if is_key_type(&second) {
		(None, second, after)
	} else {
		let (key_type, after) = word(after)?;
		(Some(options(&second)?), key_type, after)
	};
	let (base64, _) = word(after)?;
	let key = PublicKey::from_openssh(&format!("{key_type} {base64}")).ok()?;
	Some(Signer { principal, namespaces: namespaces.flatten(), key })
}

fn is_key_type(word: &str) -> bool {
	word.starts_with("ssh-") || word.starts_with("sk-") || word.starts_with("ecdsa-")
}

/// The first whitespace separated word, a double quoted one taken whole, and what follows it.
fn word(text: &str) -> Option<(String, &str)> {
	let text = text.trim_start();
	let mut quoted = false;
	let mut end = text.len();
	let mut escaped = false;
	for (index, c) in text.char_indices() {
		if escaped {
			escaped = false;
		} else if c == '\\' && quoted {
			escaped = true;
		} else if c == '"' {
			quoted = !quoted;
		} else if c.is_whitespace() && !quoted {
			end = index;
			break;
		}
	}
	let (head, tail) = text.split_at_checked(end)?;
	(!head.is_empty() && !quoted && !escaped).then(|| (head.to_owned(), tail))
}

/// Reads comma separated options while preserving commas inside quoted namespace lists.
fn options(mut field: &str) -> Option<Option<Vec<String>>> {
	let mut namespaces = None;
	while !field.is_empty() {
		let rest = field.strip_prefix("namespaces=")?;
		if namespaces.is_some() {
			return None;
		}
		let quoted = rest.strip_prefix('"')?;
		let (list, rest) = quoted.split_once('"')?;
		if list.is_empty() || list.contains(['*', '?', '!', '"', '\\']) {
			return None;
		}
		let names: Vec<_> = list.split(',').map(str::to_owned).collect();
		if names.iter().any(String::is_empty) {
			return None;
		}
		namespaces = Some(names);
		if rest.is_empty() {
			break;
		}
		field = rest.strip_prefix(',')?;
		if field.is_empty() {
			return None;
		}
	}
	Some(namespaces)
}
