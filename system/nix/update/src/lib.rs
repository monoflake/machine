//! A machine's signed updates, its system and its driver taken from the bucket's pointers, the
//! shell of `system/nix/update/` rewritten in Rust, RFC cbtjl.

pub mod archive;
pub mod bucket;
pub mod config;
pub mod effects;
pub mod flow;
pub mod host;
pub mod output;
pub mod pointer;
pub mod signature;
pub mod state;
pub mod store;
pub mod tls;
