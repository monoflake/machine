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
			&& signer
				.namespaces
				.as_ref()
				.is_none_or(|list| list.iter().any(|item| item == name || item == "*"))
			&& signer.key.key_data() == signature.public_key()
			&& signer.key.verify(name, message, &signature).is_ok()
	})
}

/// One allowed signers line, its principals field whole.
struct Signer {
	principal: String,
	/// The `namespaces` option's patterns, `None` where the line sets none.
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
	for (index, c) in text.char_indices() {
		if c == '"' {
			quoted = !quoted;
		} else if c.is_whitespace() && !quoted {
			end = index;
			break;
		}
	}
	let (head, tail) = text.split_at_checked(end)?;
	(!head.is_empty()).then(|| (head.replace('"', ""), tail))
}

/// An options field that is `namespaces="a,b"` alone, the patterns of the one; `Some(None)` is
/// never returned, so the outer `Option` marks a field this verifier refuses.
fn options(field: &str) -> Option<Option<Vec<String>>> {
	let list = field.strip_prefix("namespaces=")?;
	Some(Some(list.split(',').map(str::to_owned).collect()))
}
