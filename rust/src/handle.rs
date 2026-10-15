//! Reference counted handle plumbing.
//!
//! Every `wt_*_t` opaque pointer exposed by the C ABI points at a [`Handle`]:
//! a magic/kind header followed by an `Arc`-ed payload. Cloning the `Arc`
//! before moving work onto a tokio task keeps the payload alive even when the
//! caller releases the handle while operations are still in flight.

use core::ffi::c_void;
use std::sync::Arc;

use crate::ffi::guard;
use crate::status::wt_status_t;

/// Magic written into every live handle ("WTFF").
pub(crate) const HANDLE_MAGIC: u32 = 0x5754_4646;

/// Discriminator stored in the handle header, used to reject wrong-typed
/// pointers (for example a connection handle passed where a stream is
/// expected).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub(crate) enum HandleKind {
    ClientConfig = 1,
    Client = 2,
    ServerConfig = 3,
    Server = 4,
    SessionRequest = 5,
    Connection = 6,
    SendStream = 7,
    RecvStream = 8,
    Buffer = 9,
}

/// Header shared by every handle allocation.
#[repr(C)]
pub(crate) struct HandleHeader {
    pub(crate) magic: u32,
    pub(crate) kind: u16,
    pub(crate) flags: u16,
}

/// A live handle: header + `Arc`-ed payload.
#[repr(C)]
pub(crate) struct Handle<T> {
    pub(crate) header: HandleHeader,
    pub(crate) inner: Arc<T>,
}

impl<T> Handle<T> {
    /// Allocates a handle and returns the opaque pointer handed to C.
    pub(crate) fn new(kind: HandleKind, value: T) -> *mut Handle<T> {
        let handle = Handle {
            header: HandleHeader {
                magic: HANDLE_MAGIC,
                kind: kind as u16,
                flags: 0,
            },
            inner: Arc::new(value),
        };
        Box::into_raw(Box::new(handle))
    }
}

/// Validates `ptr` and returns the handle.
///
/// # Safety
/// `ptr` must be NULL or a handle previously returned by [`Handle::new`].
pub(crate) unsafe fn handle_ref<'a, T>(
    ptr: *const Handle<T>,
    kind: HandleKind,
) -> Result<&'a Handle<T>, wt_status_t> {
    if ptr.is_null() {
        return Err(wt_status_t::WT_ERR_INVALID_ARG);
    }
    // SAFETY: the caller guarantees `ptr` came from `Handle::new`.
    let handle = unsafe { &*ptr };
    if handle.header.magic != HANDLE_MAGIC || handle.header.kind != kind as u16 {
        return Err(wt_status_t::WT_ERR_INVALID_HANDLE);
    }
    Ok(handle)
}

/// Validates `ptr` and clones the `Arc` payload out of it.
///
/// # Safety
/// Same requirements as [`handle_ref`].
pub(crate) unsafe fn handle_arc<T>(
    ptr: *const Handle<T>,
    kind: HandleKind,
) -> Result<Arc<T>, wt_status_t> {
    let handle = unsafe { handle_ref(ptr, kind)? };
    Ok(Arc::clone(&handle.inner))
}

/// Releases a handle; the payload is dropped once the last `Arc` goes away.
///
/// # Safety
/// `ptr` must be NULL or a handle from [`Handle::new`] that has not been freed.
pub(crate) unsafe fn handle_free<T>(ptr: *mut Handle<T>, kind: HandleKind) {
    guard((), || {
        if ptr.is_null() {
            return;
        }
        // Validate best-effort: the magic check cannot be airtight for a
        // pointer that was already freed, but it does catch wrong-typed
        // pointers before they corrupt the heap.
        // SAFETY: the caller guarantees `ptr` came from `Handle::new`.
        let handle = unsafe { &*ptr };
        if handle.header.magic != HANDLE_MAGIC || handle.header.kind != kind as u16 {
            crate::runtime::emit_log(
                "flutter_webtransport: refusing to free an invalid handle".to_owned(),
            );
            return;
        }
        // SAFETY: `ptr` is an owned `Box` allocation created in `Handle::new`.
        drop(unsafe { Box::from_raw(ptr) });
    });
}

/// Casts a handle pointer into the `void*` representation used by events.
#[inline]
pub(crate) fn handle_to_void<T>(ptr: *mut Handle<T>) -> *mut c_void {
    ptr as *mut c_void
}
