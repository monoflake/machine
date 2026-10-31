//! The shell scenarios over fake effects and real temporary files, each on a paused clock so the
//! driver's wait for its services passes without sleeping.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing)]

mod driver;
mod nudge;
mod support;
mod system;
