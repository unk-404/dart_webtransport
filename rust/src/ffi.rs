//! Small helpers shared by every `extern "C"` entry point.

use core::ffi::c_char;
use std::ffi::{CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::status::wt_status_t;

/// Runs `f`, converting a Rust panic into `fallback` instead of letting the
/// unwind cross the FFI boundary (which would abort the host application).
#[inline]
pub(crate) fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(value) => value,
        Err(_) => {
            crate::runtime::emit_log(
                "flutter_webtransport: panic caught at the FFI boundary".to_owned(),
            );
            fallback
        }
    }
}

/// Reads a NUL-terminated UTF-8 string.
///
/// # Safety
/// `ptr` must be NULL or point to a valid NUL-terminated string.
#[inline]
pub(crate) unsafe fn opt_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

/// Like [`opt_str`] but fails with `WT_ERR_INVALID_ARG` for NULL/invalid UTF-8.
#[inline]
pub(crate) unsafe fn req_str<'a>(ptr: *const c_char) -> Result<&'a str, wt_status_t> {
    unsafe { opt_str(ptr) }.ok_or(wt_status_t::WT_ERR_INVALID_ARG)
}

/// Builds a byte slice from raw parts.
///
/// # Safety
/// `ptr` must be valid for `len` bytes for the lifetime of the returned slice.
#[inline]
pub(crate) unsafe fn slice_from_raw<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        return &[];
    }
    unsafe { core::slice::from_raw_parts(ptr, len) }
}

/// Mutable counterpart of [`slice_from_raw`].
///
/// # Safety
/// `ptr` must be valid for `len` mutable bytes for the lifetime of the slice.
#[inline]
pub(crate) unsafe fn slice_from_raw_mut<'a>(ptr: *mut u8, len: usize) -> &'a mut [u8] {
    if ptr.is_null() || len == 0 {
        return &mut [];
    }
    unsafe { core::slice::from_raw_parts_mut(ptr, len) }
}

/// A NUL-terminated string safe to hand to C (interior NULs are replaced).
#[inline]
pub(crate) fn cstring(text: impl AsRef<str>) -> CString {
    let text = text.as_ref();
    match CString::new(text) {
        Ok(value) => value,
        Err(_) => {
            let sanitized: String = text.replace('\0', " ");
            CString::new(sanitized).unwrap_or_default()
        }
    }
}

/// Writes `text` into a caller supplied buffer, updating `*len` with the
/// required size (including the NUL terminator) when the buffer is too small.
///
/// # Safety
/// `buffer` must be valid for `*len` writable bytes, or NULL.
pub(crate) unsafe fn write_cstr_out(    text: &str,
    buffer: *mut c_char,
    len: *mut usize,
) -> wt_status_t {
    if len.is_null() {
        return wt_status_t::WT_ERR_INVALID_ARG;
    }
    let required = text.len() + 1;
    let capacity = unsafe { *len };
    if buffer.is_null() || capacity < required {
        unsafe { *len = required };
        return wt_status_t::WT_ERR_INVALID_ARG;
    }
    unsafe {
        core::ptr::copy_nonoverlapping(text.as_ptr().cast::<c_char>(), buffer, text.len());
        *buffer.add(text.len()) = 0;
        *len = required;
    }
    wt_status_t::WT_OK
}
