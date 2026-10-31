//! Every driver shell run with real archives, signatures, links and accepted state.

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};

use machine_update::output::Output;
use machine_update::{archive, flow, host};
use serde_json::json;

use super::support::*;

async fn refused(f: &mut Fixture, reason: &str, accepted: &[u8]) {
	let (code, text) = f.fetch(false).await;
	assert_eq!(code, 1, "{text}");
	assert!(text.contains(reason), "{text}");
	assert_eq!(f.accepted(), accepted);
	assert_eq!(f.current().as_deref(), Some("1.0"));
}

async fn absent(f: &mut Fixture) {
	let before = tree(&f.paths.driver);
	let state = f.accepted();
	for key in [f.key(), format!("{}.sig", f.key())] {
		let bytes = f.bucket.objects.borrow_mut().remove(&key).unwrap();
		let (code, text) = f.fetch(false).await;
		assert_eq!(code, 0);
		assert!(text.contains("no driver pointer, nothing to do"));
		assert_eq!(tree(&f.paths.driver), before);
		assert_eq!(f.accepted(), state);
		f.bucket.objects.borrow_mut().insert(key, bytes);
	}
}

#[tokio::test(start_paused = true)]
async fn shell_driver_transcript_and_invariants() {
	let mut f = Fixture::new(true);
	let good = archive_file("driver-machine", 0o755, tar::EntryType::Regular);
	*f.download.bytes.borrow_mut() = good.clone();
	f.signed(&f.driver_pointer("1.0", 0));
	let before = tree(&f.paths.driver);
	assert_eq!(f.fetch(true).await.0, 0);
	assert_eq!(tree(&f.paths.driver), before);
	assert!(f.units.calls.borrow().is_empty());
	assert!(f.download.calls.borrow().is_empty());
	symlink("stale", f.paths.driver.join("previous")).unwrap();
	f.units.restarts.borrow_mut().push_back(true);
	let (code, text) = f.fetch(false).await;
	assert_eq!(code, 1);
	assert!(text.ends_with("update: refused, driver restart failed\n"));
	assert_eq!(f.current(), None);
	assert_eq!(f.previous(), None);
	assert!(!f.paths.accepted().exists());
	assert_eq!(
		*f.units.calls.borrow(),
		[
			"restart driver-machine.service driver-machine-entry.service",
			"stop driver-machine.service driver-machine-entry.service"
		]
	);
	assert_eq!(f.fetch(false).await.0, 0);
	assert_eq!(f.current().as_deref(), Some("1.0"));
	assert_eq!(f.previous(), None);
	for path in [f.paths.driver.join("1.0"), f.paths.driver.join("1.0/driver-machine")] {
		assert_eq!(fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o755);
	}
	let calls = f.units.calls.borrow().clone();
	assert_eq!(f.fetch(false).await.0, 0);
	assert_eq!(*f.units.calls.borrow(), calls);
	f.signed(&f.driver_pointer("1.0", 1));
	assert_eq!(f.fetch(false).await.0, 0);
	assert_eq!(*f.units.calls.borrow(), calls);
	let accepted = f.accepted();
	absent(&mut f).await;
	f.config.bucket = "fixture".into();
	for signature in [false, true] {
		let key = if signature { format!("{}.sig", f.key()) } else { f.key() };
		let bytes = f.bucket.objects.borrow().get(&key).unwrap().clone();
		for status in [404, 403, 500, 0] {
			let before = tree(&f.paths.driver);
			if status == 404 {
				f.bucket.objects.borrow_mut().remove(&key);
				let (code, text) = f.fetch(false).await;
				assert_eq!(code, 0);
				assert!(text.contains("no driver pointer"));
				f.bucket.objects.borrow_mut().insert(key.clone(), bytes.clone());
			} else {
				f.bucket.errors.borrow_mut().insert(key.clone(), status);
				refused(
					&mut f,
					if signature { "signature fetch failed" } else { "pointer fetch failed" },
					&accepted,
				)
				.await;
				f.bucket.errors.borrow_mut().clear();
			}
			assert_eq!(tree(&f.paths.driver), before);
		}
	}
	assert_eq!(f.fetch(false).await.0, 0);
	f.config.bucket = format!("file://{}", f.temporary.path().join("bucket").display());
	f.bucket.objects.borrow_mut().insert(format!("{}.sig", f.key()), b"broken".to_vec());
	refused(&mut f, "invalid driver-pointer signature", &accepted).await;
	f.publish(&f.driver_pointer("1.0", 1), "system-pointer", "ci");
	refused(&mut f, "invalid driver-pointer signature", &accepted).await;
	f.publish(&f.driver_pointer("1.0", 1), "driver-pointer", "mac");
	refused(&mut f, "invalid driver-pointer signature", &accepted).await;
	f.trust_mac();
	f.publish(&f.driver_pointer("1.0", 1), "driver-pointer", "mac");
	assert_eq!(f.fetch(false).await.0, 0);
	for mutation in 0..11 {
		let mut pointer = f.driver_pointer("2.0", 2);
		match mutation {
			0 => {
				pointer["archives"]["x86_64-linux"]["url"] =
					json!(format!("build/driver/{}.tar.gz", "0".repeat(64)))
			}
			1 => pointer["machine"] = json!("c2"),
			2 => pointer["archives"]["x86_64-linux"]["sha256"] = json!("0".repeat(64)),
			3 => pointer["archives"]["x86_64-linux"]["url"] = json!("file:///archive"),
			4 => pointer["version"] = json!(".."),
			5 => pointer["at"] = json!("2026-02-30T12:00:00Z"),
			6 => pointer["at"] = json!("2099-01-01T00:00:00Z"),
			7 => pointer["run"] = json!(""),
			8 => pointer["extra"] = json!(true),
			9 => pointer["archives"]["extra"] = json!({}),
			10 => pointer["archives"]["aarch64-linux"]["extra"] = json!(true),
			_ => unreachable!(),
		}
		f.signed(&pointer);
		refused(&mut f, "refused", &accepted).await;
	}
	f.signed(&f.driver_pointer("2.0", 0));
	refused(&mut f, "older at", &accepted).await;
	let mut pointer = f.driver_pointer("2.0", 1);
	f.signed(&pointer);
	refused(&mut f, "accepted run changed pointer", &accepted).await;
	pointer["run"] = json!("other");
	f.signed(&pointer);
	refused(&mut f, "equal at from another run", &accepted).await;
	*f.download.bytes.borrow_mut() = archive_file("LICENSE-MIT", 0o644, tar::EntryType::Regular);
	f.signed(&f.driver_pointer("2.0", 2));
	refused(&mut f, "archive lacks executable", &accepted).await;
	assert!(
		fs::read_dir(&f.paths.driver).unwrap().all(|entry| !entry
			.unwrap()
			.file_name()
			.to_str()
			.unwrap()
			.starts_with(".install."))
	);
	*f.download.bytes.borrow_mut() = good.clone();
	f.signed(&f.driver_pointer("2.0", 2));
	f.units.restarts.borrow_mut().extend([true, false]);
	refused(&mut f, "driver restart failed", &accepted).await;
	assert_eq!(f.previous(), None);
	let before = tree(&f.paths.driver);
	assert_eq!(f.fetch(true).await.0, 0);
	assert_eq!(tree(&f.paths.driver), before);
	assert_eq!(f.fetch(false).await.0, 0);
	let mut pointer = f.driver_pointer("3.0", 3);
	let sha = archive::sha256(&good);
	let key = format!("build/driver/{sha}.tar.gz");
	for architecture in ["x86_64-linux", "aarch64-linux"] {
		pointer["archives"][architecture]["url"] = json!(key);
	}
	f.bucket.objects.borrow_mut().insert(key.clone(), good.clone());
	for signer in ["ci", "mac"] {
		f.publish(&pointer, "driver-pointer", signer);
		let before = tree(&f.paths.driver);
		let accepted = f.accepted();
		let downloads = f.download.calls.borrow().clone();
		let (code, text) = f.fetch(false).await;
		assert_eq!(code, 1);
		assert!(text.contains("build archives not allowed"));
		assert_eq!(tree(&f.paths.driver), before);
		assert_eq!(f.accepted(), accepted);
		assert_eq!(*f.download.calls.borrow(), downloads);
	}
	f.config.driver_builds = true;
	f.bucket.objects.borrow_mut().remove(&key);
	let before = tree(&f.paths.driver);
	let accepted = f.accepted();
	assert!(f.fetch(false).await.1.contains("archive download failed"));
	assert_eq!(tree(&f.paths.driver), before);
	assert_eq!(f.accepted(), accepted);
	f.bucket.objects.borrow_mut().insert(key.clone(), good);
	assert_eq!(f.fetch(false).await.0, 0);
	assert_eq!(f.current().as_deref(), Some("3.0"));
	assert_eq!(f.previous().as_deref(), Some("2.0"));
	assert!(!f.paths.driver.join("1.0").exists());
	let accepted = f.accepted();
	f.bucket.objects.borrow_mut().remove(&key);
	let before = tree(&f.paths.driver);
	assert_eq!(f.fetch(false).await.0, 0);
	assert_eq!(tree(&f.paths.driver), before);
	absent(&mut f).await;
	let mut stdout = Vec::new();
	let mut stderr = Vec::new();
	assert_eq!(
		flow::rollback(&f.units, &f.paths, true, &mut Output::new(&mut stdout, &mut stderr)).await,
		0
	);
	assert_eq!(stdout, b"update: rolled driver back to 2.0\n");
	assert!(stderr.is_empty());
	assert_eq!(f.current().as_deref(), Some("2.0"));
	assert_eq!(f.previous().as_deref(), Some("3.0"));
	assert_eq!(f.accepted(), accepted);
	assert_eq!(f.fetch(false).await.0, 0);
	assert_eq!(f.current().as_deref(), Some("2.0"));
	for (version, minute) in [(".1.0", 4), ("2.0", 5), ("3.0", 6)] {
		f.signed(&f.driver_pointer(version, minute));
		assert_eq!(f.fetch(false).await.0, 0);
		assert_eq!(f.current().as_deref(), Some(version));
	}
	assert_eq!(f.previous().as_deref(), Some("2.0"));
	assert!(!f.paths.driver.join(".1.0").exists());
	f.compare(include_str!("../samples/transcripts/driver.txt"));
}

#[tokio::test(start_paused = true)]
async fn unsafe_archives_download_failure_and_partial_directories() {
	let mut f = Fixture::new(true);
	for (bytes, reason) in [
		(b"broken".to_vec(), "invalid archive"),
		(archive_file("unexpected", 0o755, tar::EntryType::Regular), "unexpected archive member"),
		(
			archive_file("driver-machine", 0o755, tar::EntryType::Symlink),
			"archive contains links or special files",
		),
		(
			archive_file("driver-machine", 0o644, tar::EntryType::Regular),
			"archive lacks executable driver-machine",
		),
	] {
		*f.download.bytes.borrow_mut() = bytes;
		f.signed(&f.driver_pointer("1.0", 0));
		let (code, text) = f.fetch(false).await;
		assert_eq!(code, 1);
		assert!(text.contains(reason), "{text}");
		assert!(!f.paths.accepted().exists());
		assert_eq!(f.current(), None);
		assert!(
			fs::read_dir(&f.paths.driver)
				.unwrap()
				.all(|entry| entry.unwrap().file_name() == ".update-lock")
		);
	}
	f.download.fail.set(true);
	assert!(f.fetch(false).await.1.contains("archive download failed"));
	f.config.driver_channel = false;
	assert!(f.fetch(true).await.1.contains("driver channel disabled"));
}

#[tokio::test(start_paused = true)]
async fn restart_checks_both_services_and_restoration_can_fail() {
	let mut f = Fixture::new(true);
	*f.download.bytes.borrow_mut() = archive_file("driver-machine", 0o755, tar::EntryType::Regular);
	f.signed(&f.driver_pointer("1.0", 0));
	f.units.active.borrow_mut().extend([true, false, true, true]);
	assert_eq!(f.fetch(false).await.0, 0);
	assert_eq!(f.units.calls.borrow().iter().filter(|call| call.starts_with("is-active")).count(), 4);
	let accepted = f.accepted();
	f.signed(&f.driver_pointer("2.0", 1));
	f.units.restarts.borrow_mut().extend([true, true]);
	refused(&mut f, "restart failed and driver restoration failed", &accepted).await;
}

#[tokio::test(start_paused = true)]
async fn rollback_failures_and_failed_restart_restore_both_links() {
	let f = Fixture::new(true);
	let fixture = &f;
	let run = |root| async move {
		let f = fixture;
		let mut stdout = Vec::new();
		let mut stderr = Vec::new();
		let code =
			flow::rollback(&f.units, &f.paths, root, &mut Output::new(&mut stdout, &mut stderr)).await;
		(code, String::from_utf8(stdout).unwrap(), String::from_utf8(stderr).unwrap())
	};
	assert_eq!(run(false).await.2, "update: rollback requires root\n");
	assert_eq!(run(true).await.2, "update: current driver unavailable\n");
	host::link(&f.paths.driver, "current", "1.0").unwrap();
	assert_eq!(run(true).await.2, "update: previous driver unavailable\n");
	host::link(&f.paths.driver, "previous", "0.9").unwrap();
	assert_eq!(run(true).await.2, "update: previous binary unavailable\n");
	fs::create_dir(f.paths.driver.join("0.9")).unwrap();
	fs::write(f.paths.driver.join("0.9/driver-machine"), b"binary").unwrap();
	fs::set_permissions(f.paths.driver.join("0.9/driver-machine"), fs::Permissions::from_mode(0o755))
		.unwrap();
	f.units.restarts.borrow_mut().extend([true, false]);
	assert_eq!(
		run(true).await,
		(1, String::new(), "update: rollback restart failed, restored current link\n".into())
	);
	assert_eq!(f.current().as_deref(), Some("1.0"));
	assert_eq!(f.previous().as_deref(), Some("0.9"));
}

#[tokio::test(start_paused = true)]
async fn lock_failures_exit_without_update_messages() {
	let mut f = Fixture::new(true);
	fs::create_dir(f.paths.driver.join(".update-lock")).unwrap();
	let (code, text) = f.fetch(false).await;
	assert_eq!(code, 1);
	assert_eq!(
		text, "update: reading runtime access files\n",
		"a driver lock failure has no shell refusal line"
	);
	let mut stdout = Vec::new();
	let mut stderr = Vec::new();
	assert_eq!(
		flow::rollback(&f.units, &f.paths, true, &mut Output::new(&mut stdout, &mut stderr)).await,
		1
	);
	assert!(stdout.is_empty());
	assert!(stderr.is_empty(), "a rollback lock failure has no shell refusal line");
	assert!(f.units.calls.borrow().is_empty());
	assert!(f.bucket.calls.borrow().is_empty());
}

#[tokio::test(start_paused = true)]
async fn rollback_link_failure_never_claims_restoration() {
	for name in ["current", "previous"] {
		let f = Fixture::new(true);
		host::link(&f.paths.driver, "current", "1.0").unwrap();
		host::link(&f.paths.driver, "previous", "0.9").unwrap();
		fs::create_dir(f.paths.driver.join("0.9")).unwrap();
		let binary = f.paths.driver.join("0.9/driver-machine");
		fs::write(&binary, b"binary").unwrap();
		fs::set_permissions(binary, fs::Permissions::from_mode(0o755)).unwrap();
		*f.units.obstruct_link.borrow_mut() = Some(f.paths.driver.join(name));
		f.units.restarts.borrow_mut().push_back(true);
		let mut stdout = Vec::new();
		let mut stderr = Vec::new();
		assert_eq!(
			flow::rollback(&f.units, &f.paths, true, &mut Output::new(&mut stdout, &mut stderr)).await,
			1
		);
		assert!(stdout.is_empty());
		assert!(stderr.is_empty(), "a failed {name} restore must not claim both links were restored");
		assert_eq!(f.units.calls.borrow().len(), 1);
	}
}

#[tokio::test(start_paused = true)]
async fn inactive_after_completed_jobs_has_no_restart_detail() {
	let mut f = Fixture::new(true);
	*f.download.bytes.borrow_mut() = archive_file("driver-machine", 0o755, tar::EntryType::Regular);
	f.signed(&f.driver_pointer("1.0", 0));
	assert_eq!(f.fetch(false).await.0, 0);
	let accepted = f.accepted();
	f.signed(&f.driver_pointer("2.0", 1));
	f.units.active.borrow_mut().extend([false; 20]);
	let (code, text) = f.fetch(false).await;
	assert_eq!(code, 1);
	assert!(
		text.contains(
			"update: restarting driver services\nupdate: restart failed, restoring previous driver\n"
		),
		"completed jobs leave an empty shell restart log\n{text}"
	);
	assert!(text.ends_with("update: refused, driver restart failed\n"));
	assert_eq!(f.current().as_deref(), Some("1.0"));
	assert_eq!(f.previous(), None);
	assert_eq!(f.accepted(), accepted);
}
