//! `FIFREEZE` and `FITHAW` on the filesystem an open file lives on, behind a safe API. The kernel's
//! freeze commits the journal and writes it into place, which a plain sync does not.

use std::io;
use std::os::fd::AsFd;

/// Freezes the filesystem `fs` lives on, waiting for its writes to land.
pub fn freeze(fs: &impl AsFd) -> io::Result<()> {
	call(fs, Request::Freeze)
}

/// Thaws the filesystem `fs` lives on.
pub fn thaw(fs: &impl AsFd) -> io::Result<()> {
	call(fs, Request::Thaw)
}

#[derive(Clone, Copy)]
enum Request {
	Freeze,
	Thaw,
}

#[cfg(target_os = "linux")]
fn call(fs: &impl AsFd, request: Request) -> io::Result<()> {
	use std::os::fd::AsRawFd;

	// `FIFREEZE` is `_IOWR('X', 119, int)` and `FITHAW` is `_IOWR('X', 120, int)`.
	let number = match request {
		Request::Freeze => 119,
		Request::Thaw => 120,
	};
	let request = libc::_IOWR::<libc::c_int>(u32::from(b'X'), number);
	let ignored: libc::c_int = 0;
	// SAFETY: the descriptor is open for the call, and both requests take an int the kernel ignores.
	let result = unsafe { libc::ioctl(fs.as_fd().as_raw_fd(), request, ignored) };
	if result == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

#[cfg(not(target_os = "linux"))]
fn call(_fs: &impl AsFd, _request: Request) -> io::Result<()> {
	Err(io::Error::from(io::ErrorKind::Unsupported))
}
