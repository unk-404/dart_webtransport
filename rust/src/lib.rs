//! `wtransport` exposed as a C ABI for Dart FFI.
//!
//! The crate root re-exports every type and function of the ABI so that
//! `cbindgen` can emit a single flat header (`src/webtransport.h`)
//! which `package:ffigen` then turns into the Dart bindings.
//!
//! See the module documentation of [`runtime`] for the delivery model, and the
//! generated header for the full contract.

#![allow(non_camel_case_types)]
#![allow(clippy::missing_safety_doc)]
#![allow(clippy::too_many_arguments)]

mod buffer;
mod client;
mod config;
mod connection;
mod ffi;
mod handle;
mod runtime;
mod server;
mod status;
mod stream;
mod types;

pub use buffer::*;
pub use client::*;
pub use config::*;
pub use connection::*;
pub use runtime::*;
pub use server::*;
pub use status::*;
pub use stream::*;
pub use types::*;

use core::ffi::c_char;
use std::ffi::CString;
use std::sync::OnceLock;

/// Major version of the ABI described by the generated header.
pub const WT_ABI_VERSION_MAJOR: u32 = 1;

/// Minor version of the ABI described by the generated header.
pub const WT_ABI_VERSION_MINOR: u32 = 0;

/// Compile time ABI version packed as `(major << 16) | minor`.
pub const WT_ABI_VERSION: u32 = (WT_ABI_VERSION_MAJOR << 16) | WT_ABI_VERSION_MINOR;

/// Runtime ABI version of the loaded library, packed as `(major << 16) | minor`.
///
/// Callers should refuse to continue when the major component differs from the
/// one they were compiled against.
#[no_mangle]
pub extern "C" fn wt_abi_version() -> u32 {
    WT_ABI_VERSION
}

/// NUL-terminated static version string.
#[no_mangle]
pub extern "C" fn wt_version_string() -> *const c_char {
    static VERSION: OnceLock<CString> = OnceLock::new();
    VERSION
        .get_or_init(|| {
            ffi::cstring(concat!(
                "webtransport ",
                env!("CARGO_PKG_VERSION"),
                " (wtransport 0.7.2)"
            ))
        })
        .as_ptr()
}
