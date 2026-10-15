//! Small value types shared by several entry points.

use core::ffi::c_char;

use crate::ffi::opt_str;

/// A name/value pair; both strings are NUL-terminated UTF-8.
#[repr(C)]
pub struct wt_header_t {
    /// Header name.
    pub name: *const c_char,
    /// Header value.
    pub value: *const c_char,
}

/// Reads an array of `count` headers into owned pairs.
///
/// # Safety
/// `headers` must be NULL or point at `count` readable `wt_header_t`, each with
/// NUL-terminated UTF-8 strings.
pub(crate) unsafe fn read_headers(
    headers: *const wt_header_t,
    count: usize,
) -> Option<Vec<(String, String)>> {
    if headers.is_null() || count == 0 {
        return Some(Vec::new());
    }
    let mut out = Vec::with_capacity(count);
    for index in 0..count {
        // SAFETY: the caller guarantees an array of `count` entries.
        let entry = unsafe { &*headers.add(index) };
        // SAFETY: the caller guarantees NUL-terminated strings.
        let name = unsafe { opt_str(entry.name) }?;
        let value = unsafe { opt_str(entry.value) }?;
        out.push((name.to_owned(), value.to_owned()));
    }
    Some(out)
}
