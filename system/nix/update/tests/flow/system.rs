//! Every fetch shell run in its original order, with state and effects checked.

use std::fs;

use machine_update::host;
use serde_json::json;

use super::support::*;

async fn refused(f: &mut Fixture, reason: &str, accepted: &[u8]) {
	let (code, text) = f.fetch(false).await;
	assert_eq!(code, 1, "{text}");
	assert!(text.contains(reason), "{text}");
	assert_eq!(f.accepted(), accepted);
	assert_eq!(host::read_link(&f.paths.current_system).unwrap().as_deref(), Some(OLD));
	let generation = fs::read_link(&f.paths.profile).unwrap();
	assert_eq!(
		fs::read_link(f.paths.profile.parent().unwrap().join(generation)).unwrap().to_str(),
		Some(OLD)
	);
}

#[tokio::test]
async fn shell_fetch_transcript_and_invariants() {
	let mut f = Fixture::new(false);
	f.signed(&f.system_pointer(0, "1"));
	assert_eq!(f.fetch(true).await.0, 0);
	assert!(!f.paths.accepted().exists());
	assert!(f.store.calls.is_empty());
	assert!(f.switch.calls.borrow().is_empty());
	assert_eq!(f.fetch(false).await.0, 0);
	assert_eq!(host::read_link(&f.paths.current_system).unwrap().as_deref(), Some(NEW));
	let accepted = f.accepted();
	assert_eq!(f.store.calls.len(), 1);
	assert_eq!(f.fetch(false).await.0, 0);
	assert_eq!(f.fetch(true).await.0, 0);
	assert_eq!(f.store.calls.len(), 1);
	assert_eq!(f.switch.calls.borrow().len(), 1);
	fs::remove_file(f.paths.accepted()).unwrap();
	assert_eq!(f.fetch(false).await.0, 0);
	assert_eq!(f.accepted(), accepted);
	assert_eq!(f.switch.calls.borrow().len(), 1);
	f.reset_system();
	assert_eq!(f.fetch(false).await.0, 0);
	assert_eq!(f.switch.calls.borrow().len(), 1);
	f.bucket.objects.borrow_mut().insert(format!("{}.sig", f.key()), b"broken".to_vec());
	refused(&mut f, "invalid system-pointer signature", &accepted).await;
	f.publish(&f.system_pointer(0, "1"), "driver-pointer", "ci");
	refused(&mut f, "invalid system-pointer signature", &accepted).await;
	f.trust_mac();
	f.publish(&f.system_pointer(0, "1"), "system-pointer", "mac");
	refused(&mut f, "invalid system-pointer signature", &accepted).await;
	for (field, value, reason) in [
		("machine", json!("c2"), "another machine"),
		("path", json!("/tmp/system"), "malformed path"),
		("at", json!("tomorrow"), "malformed time"),
		("at", json!("2026-02-30T12:00:00Z"), "malformed time"),
		("at", json!("2026-10-29T15:00:01Z"), "one hour ahead"),
		("run", json!(""), "malformed run"),
		("run", json!("line\nfeed"), "malformed run"),
		("extra", json!("value"), "malformed pointer fields"),
	] {
		let mut pointer = f.system_pointer(0, "1");
		pointer[field] = value;
		f.signed(&pointer);
		refused(&mut f, reason, &accepted).await;
	}
	let mut pointer = f.system_pointer(0, "1");
	pointer["at"] = json!("2026-10-29T12:59:59Z");
	f.signed(&pointer);
	refused(&mut f, "older at", &accepted).await;
	f.signed(&f.system_pointer(0, "2"));
	refused(&mut f, "equal at from another run", &accepted).await;
	f.signed(&f.system_pointer(1, "2"));
	f.store.fail = true;
	refused(&mut f, "realise failed", &accepted).await;
	f.store.fail = false;
	let profile = f.paths.profile.clone();
	f.paths.profile = f.temporary.path().join("missing/system");
	let (code, text) = f.fetch(false).await;
	assert_eq!(code, 1);
	assert!(text.contains("profile update failed"));
	assert_eq!(f.accepted(), accepted);
	f.paths.profile = profile;
	f.switch.failures.borrow_mut().extend([true, false]);
	refused(&mut f, "switch failed", &accepted).await;
	{
		let switches = f.switch.calls.borrow();
		assert_eq!(switches[switches.len() - 2..], [NEW, OLD]);
	}
	assert_eq!(f.fetch(true).await.0, 0);
	assert_eq!(f.accepted(), accepted);
	f.bucket.objects.borrow_mut().remove(&format!("{}.sig", f.key()));
	refused(&mut f, "signature fetch failed", &accepted).await;
	f.signed(&f.system_pointer(1, "2"));
	f.bucket.objects.borrow_mut().remove(&f.key());
	refused(&mut f, "pointer fetch failed", &accepted).await;
	f.compare(include_str!("../samples/transcripts/fetch.txt"));
}

#[tokio::test]
async fn changed_path_malformed_state_missing_running_and_restore_failures() {
	let mut f = Fixture::new(false);
	f.signed(&f.system_pointer(0, "1"));
	assert_eq!(f.fetch(false).await.0, 0);
	let accepted = f.accepted();
	f.reset_system();
	let mut pointer = f.system_pointer(0, "1");
	pointer["path"] = json!(OLD);
	f.signed(&pointer);
	refused(&mut f, "accepted run changed path", &accepted).await;
	fs::write(f.paths.accepted(), b"broken").unwrap();
	assert!(f.fetch(false).await.1.contains("recorded state malformed"));
	fs::write(f.paths.accepted(), &accepted).unwrap();
	f.signed(&f.system_pointer(1, "2"));
	fs::remove_file(&f.paths.current_system).unwrap();
	assert!(f.fetch(false).await.1.contains("running system unavailable"));
	f.reset_system();
	f.switch.failures.borrow_mut().extend([true, true]);
	refused(&mut f, "switch failed and system restoration failed", &accepted).await;
}

#[test]
fn arguments_and_runtime_access_refuse_before_effects() {
	use machine_update::config::Instance;
	use machine_update::flow;
	use machine_update::output::{Output, Refusal};
	let args = |words: &[&str]| {
		flow::arguments(&words.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>())
	};
	assert_eq!(args(&[]), Ok((Instance::System, false)));
	assert_eq!(args(&["--dry-run"]), Ok((Instance::System, true)));
	assert_eq!(args(&["driver", "--dry-run"]), Ok((Instance::Driver, true)));
	for words in [vec!["other"], vec!["--dry-run", "system"], vec!["system", "extra"]] {
		assert_eq!(args(&words), Err(Refusal::Arguments));
	}
	let mut f = Fixture::new(false);
	let mut stdout = Vec::new();
	let mut stderr = Vec::new();
	let mut out = Output::new(&mut stdout, &mut stderr);
	assert!(flow::access(&f.config, Some(&f.config.credentials_file), &mut out).is_ok());
	assert!(matches!(flow::access(&f.config, None, &mut out), Err(Refusal::CredentialsPath)));
	let alternate = f.temporary.path().join("./credentials");
	assert!(matches!(
		flow::access(&f.config, Some(&alternate), &mut out),
		Err(Refusal::CredentialsPath)
	));
	f.config.bucket = "INVALID".into();
	assert!(matches!(
		flow::access(&f.config, Some(&f.config.credentials_file), &mut out),
		Err(Refusal::Bucket)
	));
	f.config.bucket = "fixture".into();
	fs::write(&f.config.endpoint_file, "http://private.example.invalid").unwrap();
	assert!(matches!(
		flow::access(&f.config, Some(&f.config.credentials_file), &mut out),
		Err(Refusal::EndpointMalformed)
	));
	fs::write(&f.config.credentials_file, "[systems]\naws_access_key_id = only\n").unwrap();
	assert!(matches!(
		flow::access(&f.config, Some(&f.config.credentials_file), &mut out),
		Err(Refusal::Credentials)
	));
	fs::remove_file(&f.config.endpoint_file).unwrap();
	assert!(matches!(
		flow::access(&f.config, Some(&f.config.credentials_file), &mut out),
		Err(Refusal::Endpoint)
	));
	assert!(f.bucket.calls.borrow().is_empty());
}

#[tokio::test]
async fn a_failed_profile_restoration_keeps_the_accepted_pointer() {
	let mut f = Fixture::new(false);
	f.signed(&f.system_pointer(0, "1"));
	assert_eq!(f.fetch(false).await.0, 0);
	let accepted = f.accepted();
	f.reset_system();
	f.signed(&f.system_pointer(1, "2"));
	f.switch.failures.borrow_mut().push_back(true);
	*f.switch.obstruct_profile.borrow_mut() = Some(f.paths.profile.clone());
	let (code, text) = f.fetch(false).await;
	assert_eq!(code, 1);
	assert!(text.ends_with("update: refused, switch failed and profile restoration failed\n"));
	assert_eq!(f.accepted(), accepted);
}
