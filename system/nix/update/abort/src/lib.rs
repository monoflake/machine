//! The line a process writes as SIGABRT kills it, naming its last step, RFC cbtjl item 10.
//! This crate holds the only `unsafe` of this repository, behind a safe API.

use std::ffi::c_int;
use std::sync::atomic::{AtomicPtr, Ordering};

static NONE: &str = "none";
static LAST: AtomicPtr<&'static str> = AtomicPtr::new(std::ptr::from_ref(&NONE).cast_mut());

/// Sets the step a later SIGABRT names.
pub fn note(step: &'static &'static str) {
	LAST.store(std::ptr::from_ref(step).cast_mut(), Ordering::Release);
}

/// Installs the handler for this process.
pub fn install() {
	// libc takes a handler as its address, which only `as` gives.
	#[expect(clippy::as_conversions)]
	let address = handler as extern "C" fn(c_int) as *const () as libc::sighandler_t;
	// SAFETY: the handler makes only async-signal-safe calls and touches one atomic.
	unsafe { libc::signal(libc::SIGABRT, address) };
}

extern "C" fn handler(_signal: c_int) {
	// SAFETY: every pointer `LAST` holds came from a `&'static &'static str`.
	let step: &str = unsafe { *LAST.load(Ordering::Acquire) };
	write(b"update: aborted by SIGABRT, last step ");
	write(step.as_bytes());
	write(b"\n");
	// SAFETY: both are async-signal-safe, and the raised signal waits for this handler's return.
	unsafe {
		libc::signal(libc::SIGABRT, libc::SIG_DFL);
		libc::raise(libc::SIGABRT);
	}
}

fn write(bytes: &[u8]) {
	// SAFETY: the pointer and length describe one live slice, and write is async-signal-safe.
	unsafe { libc::write(libc::STDERR_FILENO, bytes.as_ptr().cast(), bytes.len()) };
}
