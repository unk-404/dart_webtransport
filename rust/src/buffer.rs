//! Native byte buffers.
//!
//! These back the zero-copy half of the binding: Dart allocates a buffer here,
//! wraps the raw pointer in a `Uint8List` view, and both sides then operate on
//! exactly the same memory. The transport reads *directly* into it, so a
//! received stream chunk reaches Dart without a single copy.

use core::ffi::c_void;
use std::alloc::{alloc, dealloc, realloc, Layout};
use std::sync::atomic::{AtomicPtr, AtomicUsize, Ordering};
use std::sync::Mutex;

use crate::ffi::guard;
use crate::handle::{handle_arc, handle_free, Handle, HandleKind};
use crate::status::wt_status_t;

/// Opaque handle to a native byte buffer.
///
/// Create with `wt_buffer_new`, release with `wt_buffer_free`. The pointer
/// returned by `wt_buffer_data` stays valid until the handle is released
/// (including by every `wt_recv_stream_read` that referenced it).
#[repr(C)]
pub struct wt_buffer_t {
    _opaque: *mut c_void,
}

/// Implementation behind [`wt_buffer_t`].
///
/// Fields are atomic because the handle is shared: Dart reads the pointer and
/// length while tokio tasks may still be filling the same storage.
pub(crate) struct Buffer {
    ptr: AtomicPtr<u8>,
    capacity: AtomicUsize,
    len: AtomicUsize,
    resize: Mutex<()>,
}

/// Number of live [`wt_buffer_t`] handles (diagnostics + leak tests).
static LIVE_BUFFERS: AtomicUsize = AtomicUsize::new(0);

/// Allocator layout used for every buffer and for `wt_alloc`.
#[inline]
fn layout_for(capacity: usize) -> Layout {
    Layout::from_size_align(capacity.max(1), 1).expect("valid layout")
}

impl Buffer {
    fn new(capacity: usize) -> Option<Buffer> {
        let capacity = capacity.max(1);
        // SAFETY: `layout_for` always yields a non-zero size.
        let ptr = unsafe { alloc(layout_for(capacity)) };
        if ptr.is_null() {
            return None;
        }
        Some(Buffer {
            ptr: AtomicPtr::new(ptr),
            capacity: AtomicUsize::new(capacity),
            len: AtomicUsize::new(0),
            resize: Mutex::new(()),
        })
    }

    #[inline]
    pub(crate) fn data(&self) -> *mut u8 {
        self.ptr.load(Ordering::Acquire)
    }

    #[inline]
    pub(crate) fn capacity(&self) -> usize {
        self.capacity.load(Ordering::Relaxed)
    }

    #[inline]
    pub(crate) fn len(&self) -> usize {
        self.len.load(Ordering::Relaxed)
    }

    pub(crate) fn set_len(&self, length: usize) -> wt_status_t {
        if length > self.capacity() {
            return wt_status_t::WT_ERR_INVALID_ARG;
        }
        self.len.store(length, Ordering::Release);
        wt_status_t::WT_OK
    }

    pub(crate) fn reserve(&self, capacity: usize) -> wt_status_t {
        let wanted = capacity.max(1);
        if wanted <= self.capacity() {
            return wt_status_t::WT_OK;
        }
        let _lock = self.resize.lock().unwrap_or_else(|e| e.into_inner());
        let current = self.capacity();
        if wanted <= current {
            return wt_status_t::WT_OK;
        }
        let old_ptr = self.data();
        // SAFETY: `old_ptr` was allocated by `alloc`/`realloc` with `layout_for(current)`.
        let new_ptr = unsafe { realloc(old_ptr, layout_for(current), wanted) };
        if new_ptr.is_null() {
            return wt_status_t::WT_ERR_IO;
        }
        self.ptr.store(new_ptr, Ordering::Release);
        self.capacity.store(wanted, Ordering::Release);
        let len = self.len();
        if len > wanted {
            self.len.store(wanted, Ordering::Release);
        }
        wt_status_t::WT_OK
    }
}

impl Drop for Buffer {
    fn drop(&mut self) {
        let capacity = self.capacity.load(Ordering::Relaxed);
        let ptr = self.ptr.load(Ordering::Relaxed);
        if !ptr.is_null() {
            // SAFETY: allocated with `layout_for(capacity)` by this struct.
            unsafe { dealloc(ptr, layout_for(capacity)) };
        }
    }
}

/// Allocates `capacity` bytes (uninitialised, logical length starts at 0).
///
/// Returns NULL on allocation failure.
#[no_mangle]
pub extern "C" fn wt_buffer_new(capacity: usize) -> *mut wt_buffer_t {
    guard(core::ptr::null_mut(), || match Buffer::new(capacity) {
        Some(buffer) => {
            LIVE_BUFFERS.fetch_add(1, Ordering::Relaxed);
            Handle::new(HandleKind::Buffer, buffer).cast()
        }
        None => core::ptr::null_mut(),
    })
}

/// Grows the buffer to at least `capacity` bytes, preserving its contents.
#[no_mangle]
pub unsafe extern "C" fn wt_buffer_reserve(
    buffer: *mut wt_buffer_t,
    capacity: usize,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        match unsafe { handle_arc(buffer as *const Handle<Buffer>, HandleKind::Buffer) } {
            Ok(inner) => inner.reserve(capacity),
            Err(status) => status,
        }
    })
}

/// Writable pointer to the buffer contents.
///
/// The pointer must be requested again after `wt_buffer_reserve`.
#[no_mangle]
pub unsafe extern "C" fn wt_buffer_data(buffer: *mut wt_buffer_t) -> *mut u8 {
    guard(core::ptr::null_mut(), || {
        match unsafe { handle_arc(buffer as *const Handle<Buffer>, HandleKind::Buffer) } {
            Ok(inner) => inner.data(),
            Err(_) => core::ptr::null_mut(),
        }
    })
}

/// Read-only pointer to the buffer contents.
#[no_mangle]
pub unsafe extern "C" fn wt_buffer_data_const(buffer: *const wt_buffer_t) -> *const u8 {
    guard(core::ptr::null(), || {
        match unsafe { handle_arc(buffer as *const Handle<Buffer>, HandleKind::Buffer) } {
            Ok(inner) => inner.data() as *const u8,
            Err(_) => core::ptr::null(),
        }
    })
}

/// Allocated capacity in bytes.
#[no_mangle]
pub unsafe extern "C" fn wt_buffer_capacity(buffer: *const wt_buffer_t) -> usize {
    guard(0, || {
        match unsafe { handle_arc(buffer as *const Handle<Buffer>, HandleKind::Buffer) } {
            Ok(inner) => inner.capacity(),
            Err(_) => 0,
        }
    })
}

/// Logical length in bytes.
#[no_mangle]
pub unsafe extern "C" fn wt_buffer_len(buffer: *const wt_buffer_t) -> usize {
    guard(0, || {
        match unsafe { handle_arc(buffer as *const Handle<Buffer>, HandleKind::Buffer) } {
            Ok(inner) => inner.len(),
            Err(_) => 0,
        }
    })
}

/// Sets the logical length; must not exceed the capacity.
#[no_mangle]
pub unsafe extern "C" fn wt_buffer_set_len(
    buffer: *mut wt_buffer_t,
    length: usize,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        match unsafe { handle_arc(buffer as *const Handle<Buffer>, HandleKind::Buffer) } {
            Ok(inner) => inner.set_len(length),
            Err(status) => status,
        }
    })
}

/// Releases the buffer handle.
///
/// The storage itself is only released once every in-flight operation that
/// referenced it has finished, so callers must not release a buffer while a
/// `wt_recv_stream_read` writing into it is still outstanding.
#[no_mangle]
pub unsafe extern "C" fn wt_buffer_free(buffer: *mut wt_buffer_t) {
    if buffer.is_null() {
        return;
    }
    LIVE_BUFFERS.fetch_sub(1, Ordering::Relaxed);
    unsafe { handle_free(buffer as *mut Handle<Buffer>, HandleKind::Buffer) };
}

/// Allocates `size` bytes from the same allocator used by `wt_buffer_t`.
#[no_mangle]
pub extern "C" fn wt_alloc(size: usize) -> *mut u8 {
    guard(core::ptr::null_mut(), || {
        // SAFETY: `layout_for` always yields a non-zero size.
        unsafe { alloc(layout_for(size)) }
    })
}

/// Frees memory previously returned by `wt_alloc`.
#[no_mangle]
pub unsafe extern "C" fn wt_dealloc(data: *mut u8, size: usize) {
    if data.is_null() {
        return;
    }
    // SAFETY: the caller promises this came from `wt_alloc`.
    unsafe { dealloc(data, layout_for(size)) };
}

/// Current number of live native buffers.
#[no_mangle]
pub extern "C" fn wt_live_buffer_count() -> usize {
    LIVE_BUFFERS.load(Ordering::Relaxed)
}
