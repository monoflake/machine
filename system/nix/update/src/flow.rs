//! The four update runs over replaceable effects and paths.

use std::fs;
use std::hash::BuildHasher;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::bucket::{self, Remote};
use crate::config::{Config, Instance, Paths};
use crate::effects::{Bucket, Clock, Units};
use crate::output::{Output, Refusal, Secrets, Step};
use crate::signature::{self, Namespace};
use crate::{host, state};

mod driver;
mod nudge;
mod rollback;
mod system;

pub use driver::fetch_driver;
pub use nudge::nudge;
pub use rollback::rollback;
pub use system::fetch_system;

const SERVICES: &[&str] = &["driver-machine.service", "driver-machine-entry.service"];

/// Parses the fetch arguments in the order the shell accepted them.
pub fn arguments(args: &[String]) -> Result<(Instance, bool), Refusal> {
	let mut args = args.iter().map(String::as_str).peekable();
	let instance = match args.peek() {
		Some(&"system") => {
			args.next();
			Instance::System
		}
		Some(&"driver") => {
			args.next();
			Instance::Driver
		}
		_ => Instance::System,
	};
	let dry = args.peek() == Some(&"--dry-run");
	if dry {
		args.next();
	}
	if args.next().is_some() {
		return Err(Refusal::Arguments);
	}
	Ok((instance, dry))
}

/// Reads runtime access files before any bucket operation.
pub fn access(
	config: &Config,
	credentials_path: Option<&Path>,
	out: &mut Output<'_>,
) -> Result<(Remote, Secrets), Refusal> {
	out.say(Step::ReadingAccess);
	let endpoint = fs::read_to_string(&config.endpoint_file).map_err(|_| Refusal::Endpoint)?;
	if credentials_path.map(Path::as_os_str) != Some(config.credentials_file.as_os_str()) {
		return Err(Refusal::CredentialsPath);
	}
	let text = fs::read_to_string(&config.credentials_file).map_err(|_| Refusal::Credentials)?;
	let credentials = bucket::credentials(&text)?;
	let endpoint = endpoint.trim_end_matches('\n');
	let host = endpoint.strip_prefix("https://").unwrap_or(endpoint);
	let secrets = Secrets {
		host: host.strip_suffix('/').unwrap_or(host).to_owned(),
		key: credentials.key.clone(),
		secret: credentials.secret.clone(),
	};
	let remote = Remote::new(&config.bucket, endpoint, credentials)?;
	Ok((remote, secrets))
}

async fn incoming(
	bucket: &impl Bucket,
	config: &Config,
	driver: bool,
	out: &mut Output<'_>,
) -> Result<Option<Vec<u8>>, Refusal> {
	out.say(if driver { Step::FetchingDriverPointer } else { Step::FetchingSystemPointer });
	let key = format!("pointer/{}/{}", if driver { "driver" } else { "system" }, config.machine);
	let bytes = match bucket.get(&key).await.map_err(|_| Refusal::PointerFetch)? {
		Some(bytes) => bytes,
		None if driver => {
			out.say(Step::NoDriverPointer);
			return Ok(None);
		}
		None => return Err(Refusal::PointerFetch),
	};
	out.say(Step::FetchingSignature);
	let signature =
		match bucket.get(&format!("{key}.sig")).await.map_err(|_| Refusal::SignatureFetch)? {
			Some(bytes) => bytes,
			None if driver => {
				out.say(Step::NoDriverPointer);
				return Ok(None);
			}
			None => return Err(Refusal::SignatureFetch),
		};
	out.say(if driver { Step::VerifyingDriverSignature } else { Step::VerifyingSystemSignature });
	let signers = if driver { &config.driver_signers } else { &config.signers };
	let namespace = if driver { Namespace::Driver } else { Namespace::System };
	let verified = fs::read_to_string(signers)
		.is_ok_and(|signers| signature::verify(&signers, namespace, &bytes, &signature));
	if !verified {
		return Err(if driver { Refusal::DriverSignature } else { Refusal::SystemSignature });
	}
	out.say(if driver { Step::ValidatingDriverPointer } else { Step::ValidatingSystemPointer });
	Ok(Some(bytes))
}

fn record(paths: &Paths, bytes: &[u8], out: &mut Output<'_>) -> std::io::Result<()> {
	state::record(&paths.accepted(), bytes)?;
	out.say(Step::Recorded);
	Ok(())
}

fn finish(result: Result<(), Refusal>, out: &mut Output<'_>) -> i32 {
	match result {
		Ok(()) => 0,
		Err(reason) => {
			out.refuse(reason);
			1
		}
	}
}

async fn restart(units: &impl Units) -> Result<(), crate::effects::UnitError> {
	units.restart(SERVICES).await?;
	for _ in 0..20 {
		if units.is_active("driver-machine.service").await.unwrap_or(false)
			&& units.is_active("driver-machine-entry.service").await.unwrap_or(false)
		{
			return Ok(());
		}
		tokio::time::sleep(std::time::Duration::from_secs(1)).await;
	}
	Err(crate::effects::UnitError::Timeout)
}

struct Temporary(PathBuf);

impl Temporary {
	fn beside(root: &Path) -> std::io::Result<Self> {
		static NEXT: AtomicU64 = AtomicU64::new(0);
		loop {
			let suffix = std::collections::hash_map::RandomState::new()
				.hash_one((std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)))
				& 0xff_ffff;
			let path = root.join(format!(".install.{suffix:06x}"));
			match fs::DirBuilder::new().mode(0o700).create(&path) {
				Ok(()) => return Ok(Self(path)),
				Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
				Err(error) => return Err(error),
			}
		}
	}
}

impl Drop for Temporary {
	fn drop(&mut self) {
		let _ = fs::remove_dir_all(&self.0);
	}
}

fn remove_link(root: &Path, name: &str) -> std::io::Result<()> {
	match fs::remove_file(root.join(name)) {
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
		result => result,
	}
}

fn link(root: &Path, name: &str) -> Option<String> {
	host::read_link(&root.join(name)).ok().flatten()
}
