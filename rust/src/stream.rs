//! Send and receive streams.
//!
//! Each stream handle serialises its operations: `wt_send_stream_write` and
//! `wt_recv_stream_read` acquire a per-stream busy flag and answer
//! `WT_ERR_OP_BUSY` when a second operation is issued before the first
//! completion arrived. That keeps the byte ordering deterministic without
//! forcing the Dart side to serialise anything itself.

use core::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;

use tokio::sync::Mutex as AsyncMutex;
use wtransport::error::{
    StreamOpeningError, StreamReadError, StreamReadExactError, StreamWriteError,
};
use wtransport::{RecvStream, SendStream, VarInt};

use crate::ffi::{guard, slice_from_raw};
use crate::handle::{handle_arc, handle_free, handle_to_void, Handle, HandleKind};
use crate::runtime::{spawn_event_task, with_rt, Event, EventData, wt_op_t};
use crate::status::wt_status_t;

/// Opaque handle to a sending half of a stream.
#[repr(C)]
pub struct wt_send_stream_t {
    _opaque: *mut c_void,
}

/// Opaque handle to a receiving half of a stream.
#[repr(C)]
pub struct wt_recv_stream_t {
    _opaque: *mut c_void,
}

/// Payload behind [`wt_send_stream_t`].
pub(crate) struct SendStreamInner {
    pub(crate) id: u64,
    pub(crate) busy: Arc<AtomicBool>,
    pub(crate) priority: AtomicI32,
    pub(crate) stream: AsyncMutex<Option<SendStream>>,
}

/// Payload behind [`wt_recv_stream_t`].
pub(crate) struct RecvStreamInner {
    pub(crate) id: u64,
    pub(crate) busy: Arc<AtomicBool>,
    pub(crate) stream: AsyncMutex<Option<RecvStream>>,
}

/// Wraps a [`SendStream`] into an event payload handle.
pub(crate) fn new_send_stream_handle(stream: SendStream) -> *mut c_void {
    let id = stream.id().into_u64();
    handle_to_void(Handle::new(
        HandleKind::SendStream,
        SendStreamInner {
            id,
            busy: Arc::new(AtomicBool::new(false)),
            priority: AtomicI32::new(0),
            stream: AsyncMutex::new(Some(stream)),
        },
    ))
}

/// Wraps a [`RecvStream`] into an event payload handle.
pub(crate) fn new_recv_stream_handle(stream: RecvStream) -> *mut c_void {
    let id = stream.id().into_u64();
    handle_to_void(Handle::new(
        HandleKind::RecvStream,
        RecvStreamInner {
            id,
            busy: Arc::new(AtomicBool::new(false)),
            stream: AsyncMutex::new(Some(stream)),
        },
    ))
}

/// Maps a stream write failure onto a status code.
pub(crate) fn map_stream_write_error(error: &StreamWriteError) -> wt_status_t {
    match error {
        StreamWriteError::NotConnected => wt_status_t::WT_ERR_NOT_CONNECTED,
        StreamWriteError::Closed => wt_status_t::WT_ERR_STREAM_CLOSED,
        StreamWriteError::Stopped(_) => wt_status_t::WT_ERR_STREAM_STOPPED,
        StreamWriteError::QuicProto => wt_status_t::WT_ERR_STREAM_WRITE,
    }
}

/// Maps a stream read failure onto a status code.
pub(crate) fn map_stream_read_error(error: &StreamReadError) -> wt_status_t {
    match error {
        StreamReadError::NotConnected => wt_status_t::WT_ERR_NOT_CONNECTED,
        StreamReadError::Reset(_) => wt_status_t::WT_ERR_STREAM_RESET,
        StreamReadError::QuicProto => wt_status_t::WT_ERR_STREAM_READ,
    }
}

/// Maps a stream opening failure onto a status code.
pub(crate) fn map_stream_opening_error(error: &StreamOpeningError) -> wt_status_t {
    match error {
        StreamOpeningError::NotConnected => wt_status_t::WT_ERR_NOT_CONNECTED,
        StreamOpeningError::Refused => wt_status_t::WT_ERR_STREAM_CLOSED,
    }
}

/// Extracts the error code carried by the given write/read failure, if any.
fn stream_error_code_write(error: &StreamWriteError) -> u64 {
    match error {
        StreamWriteError::Stopped(code) => code.into_inner(),
        _ => 0,
    }
}

fn stream_error_code_read(error: &StreamReadError) -> u64 {
    match error {
        StreamReadError::Reset(code) => code.into_inner(),
        _ => 0,
    }
}

/// Releases the per-stream busy flag when the operation finishes.
struct BusyGuard {
    flag: Arc<AtomicBool>,
}

impl BusyGuard {
    fn acquire(flag: &Arc<AtomicBool>) -> Option<BusyGuard> {
        if flag
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            Some(BusyGuard {
                flag: Arc::clone(flag),
            })
        } else {
            None
        }
    }
}

impl Drop for BusyGuard {
    fn drop(&mut self) {
        self.flag.store(false, Ordering::Release);
    }
}

/// Caller supplied destination memory that is safe to move into a tokio task.
///
/// The contract of `wt_recv_stream_read` guarantees the memory stays alive and
/// untouched until the completion event, so the only requirement is that the
/// pointer itself may cross threads.
#[derive(Clone, Copy)]
struct RawBuffer {
    ptr: *mut u8,
    len: usize,
}

// SAFETY: the pointer is only ever handed to the single spawned read task, and
// the caller promised not to touch the memory until that task completes.
unsafe impl Send for RawBuffer {}

impl RawBuffer {
    #[inline]
    fn as_mut_slice(&self) -> &mut [u8] {
        if self.ptr.is_null() || self.len == 0 {
            return &mut [];
        }
        // SAFETY: the caller of the FFI entry point guarantees `ptr` is valid
        // for `len` writable bytes for the duration of the operation.
        unsafe { core::slice::from_raw_parts_mut(self.ptr, self.len) }
    }
}

/// Where a read should put its bytes.
enum ReadTarget {
    /// Read into a library owned vector delivered through the event.
    Owned(usize),
    /// Read straight into caller supplied memory (zero copy).
    Raw(RawBuffer),
}

/// Reads the shared send-stream payload.
fn send_stream_arc(
    stream: *mut wt_send_stream_t,
) -> Result<Arc<SendStreamInner>, wt_status_t> {
    // SAFETY: the caller guarantees `stream` is a live handle of this kind.
    unsafe { handle_arc(stream as *const Handle<SendStreamInner>, HandleKind::SendStream) }
}

/// Reads the shared receive-stream payload.
fn recv_stream_arc(
    stream: *mut wt_recv_stream_t,
) -> Result<Arc<RecvStreamInner>, wt_status_t> {
    // SAFETY: the caller guarantees `stream` is a live handle of this kind.
    unsafe { handle_arc(stream as *const Handle<RecvStreamInner>, HandleKind::RecvStream) }
}

// ---------------------------------------------------------------------------
// Send streams
// ---------------------------------------------------------------------------

/// Releases a send stream handle.
#[no_mangle]
pub unsafe extern "C" fn wt_send_stream_free(stream: *mut wt_send_stream_t) {
    unsafe { handle_free(stream as *mut Handle<SendStreamInner>, HandleKind::SendStream) };
}

/// QUIC stream id.
#[no_mangle]
pub unsafe extern "C" fn wt_send_stream_id(stream: *mut wt_send_stream_t) -> u64 {
    guard(0, || match send_stream_arc(stream) {
        Ok(inner) => inner.id,
        Err(_) => 0,
    })
}

/// Stream priority (initial: 0).
#[no_mangle]
pub unsafe extern "C" fn wt_send_stream_priority(stream: *mut wt_send_stream_t) -> i32 {
    guard(0, || match send_stream_arc(stream) {
        Ok(inner) => inner.priority.load(Ordering::Relaxed),
        Err(_) => 0,
    })
}

/// Sets the stream priority.
#[no_mangle]
pub unsafe extern "C" fn wt_send_stream_set_priority(
    stream: *mut wt_send_stream_t,
    priority: i32,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match send_stream_arc(stream) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        inner.priority.store(priority, Ordering::Relaxed);
        with_rt(|| match inner.stream.try_lock() {
            Ok(lock) => {
                if let Some(stream) = lock.as_ref() {
                    stream.set_priority(priority);
                    wt_status_t::WT_OK
                } else {
                    wt_status_t::WT_ERR_STREAM_CLOSED
                }
            }
            Err(_) => wt_status_t::WT_ERR_OP_BUSY,
        })
        .unwrap_or(wt_status_t::WT_ERR_NO_RUNTIME)
    })
}

/// Writes `len` bytes; may write fewer (`aux` reports the amount).
///
/// The payload is copied, so `data` may be reused as soon as the call returns.
/// Completion: `WT_OP_STREAM_WRITE` with `aux` = bytes written.
#[no_mangle]
pub unsafe extern "C" fn wt_send_stream_write(
    stream: *mut wt_send_stream_t,
    data: *const u8,
    len: usize,
    op_id: u64,
) -> wt_status_t {
    // SAFETY: the caller guarantees `len` readable bytes.
    let payload = unsafe { slice_from_raw(data, len) }.to_vec();
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match send_stream_arc(stream) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        let Some(busy) = BusyGuard::acquire(&inner.busy) else {
            return wt_status_t::WT_ERR_OP_BUSY;
        };
        spawn_event_task(async move {
            let _busy = busy;
            let mut lock = inner.stream.lock().await;
            let Some(target) = lock.as_mut() else {
                return Event::error(
                    wt_op_t::WT_OP_STREAM_WRITE,
                    op_id,
                    wt_status_t::WT_ERR_STREAM_CLOSED,
                    "the stream was already finished or reset".to_owned(),
                );
            };
            match target.write(&payload).await {
                Ok(written) => {
                    Event::ok_aux(wt_op_t::WT_OP_STREAM_WRITE, op_id, written as u64)
                }
                Err(error) => Event::error(
                    wt_op_t::WT_OP_STREAM_WRITE,
                    op_id,
                    map_stream_write_error(&error),
                    error.to_string(),
                )
                .with_aux(stream_error_code_write(&error)),
            }
        })
    })
}

/// Writes all `len` bytes or fails.
///
/// Completion: `WT_OP_STREAM_WRITE_ALL` with `aux` = `len`.
#[no_mangle]
pub unsafe extern "C" fn wt_send_stream_write_all(
    stream: *mut wt_send_stream_t,
    data: *const u8,
    len: usize,
    op_id: u64,
) -> wt_status_t {
    // SAFETY: the caller guarantees `len` readable bytes.
    let payload = unsafe { slice_from_raw(data, len) }.to_vec();
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match send_stream_arc(stream) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        let Some(busy) = BusyGuard::acquire(&inner.busy) else {
            return wt_status_t::WT_ERR_OP_BUSY;
        };
        let total = payload.len() as u64;
        spawn_event_task(async move {
            let _busy = busy;
            let mut lock = inner.stream.lock().await;
            let Some(target) = lock.as_mut() else {
                return Event::error(
                    wt_op_t::WT_OP_STREAM_WRITE_ALL,
                    op_id,
                    wt_status_t::WT_ERR_STREAM_CLOSED,
                    "the stream was already finished or reset".to_owned(),
                );
            };
            match target.write_all(&payload).await {
                Ok(()) => Event::ok_aux(wt_op_t::WT_OP_STREAM_WRITE_ALL, op_id, total),
                Err(error) => Event::error(
                    wt_op_t::WT_OP_STREAM_WRITE_ALL,
                    op_id,
                    map_stream_write_error(&error),
                    error.to_string(),
                )
                .with_aux(stream_error_code_write(&error)),
            }
        })
    })
}

/// Gracefully finishes the stream. Completion: `WT_OP_STREAM_FINISH`.
#[no_mangle]
pub unsafe extern "C" fn wt_send_stream_finish(
    stream: *mut wt_send_stream_t,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match send_stream_arc(stream) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        let Some(busy) = BusyGuard::acquire(&inner.busy) else {
            return wt_status_t::WT_ERR_OP_BUSY;
        };
        spawn_event_task(async move {
            let _busy = busy;
            let mut lock = inner.stream.lock().await;
            let Some(target) = lock.as_mut() else {
                return Event::error(
                    wt_op_t::WT_OP_STREAM_FINISH,
                    op_id,
                    wt_status_t::WT_ERR_STREAM_CLOSED,
                    "the stream was already finished or reset".to_owned(),
                );
            };
            match target.finish().await {
                Ok(()) => Event::ok(wt_op_t::WT_OP_STREAM_FINISH, op_id),
                Err(error) => Event::error(
                    wt_op_t::WT_OP_STREAM_FINISH,
                    op_id,
                    map_stream_write_error(&error),
                    error.to_string(),
                )
                .with_aux(stream_error_code_write(&error)),
            }
        })
    })
}

/// Aborts the stream immediately (no event).
#[no_mangle]
pub unsafe extern "C" fn wt_send_stream_reset(
    stream: *mut wt_send_stream_t,
    error_code: u32,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match send_stream_arc(stream) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        with_rt(|| match inner.stream.try_lock() {
            Ok(mut lock) => match lock.as_mut() {
                Some(target) => match target.reset(VarInt::from_u32(error_code)) {
                    Ok(()) => wt_status_t::WT_OK,
                    Err(_) => wt_status_t::WT_ERR_STREAM_CLOSED,
                },
                None => wt_status_t::WT_ERR_STREAM_CLOSED,
            },
            Err(_) => wt_status_t::WT_ERR_OP_BUSY,
        })
        .unwrap_or(wt_status_t::WT_ERR_NO_RUNTIME)
    })
}

/// Passively waits until the peer stops the stream or it is closed.
///
/// Completion: `WT_OP_STREAM_STOPPED`.
#[no_mangle]
pub unsafe extern "C" fn wt_send_stream_stopped(
    stream: *mut wt_send_stream_t,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match send_stream_arc(stream) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        let Some(busy) = BusyGuard::acquire(&inner.busy) else {
            return wt_status_t::WT_ERR_OP_BUSY;
        };
        spawn_event_task(async move {
            let _busy = busy;
            let mut lock = inner.stream.lock().await;
            let Some(target) = lock.as_mut() else {
                return Event::error(
                    wt_op_t::WT_OP_STREAM_STOPPED,
                    op_id,
                    wt_status_t::WT_ERR_STREAM_CLOSED,
                    "the stream was already finished or reset".to_owned(),
                );
            };
            let error = target.stopped().await;
            let status = match error {
                StreamWriteError::Stopped(_) => wt_status_t::WT_OK,
                ref other => map_stream_write_error(other),
            };
            Event::error(wt_op_t::WT_OP_STREAM_STOPPED, op_id, status, error.to_string())
                .with_aux(stream_error_code_write(&error))
        })
    })
}

/// True when an operation is currently in flight on the stream.
#[no_mangle]
pub unsafe extern "C" fn wt_send_stream_is_busy(stream: *mut wt_send_stream_t) -> i32 {
    guard(0, || match send_stream_arc(stream) {
        Ok(inner) => i32::from(inner.busy.load(Ordering::Relaxed)),
        Err(_) => 0,
    })
}

// ---------------------------------------------------------------------------
// Receive streams
// ---------------------------------------------------------------------------

/// Releases a receive stream handle.
#[no_mangle]
pub unsafe extern "C" fn wt_recv_stream_free(stream: *mut wt_recv_stream_t) {
    unsafe { handle_free(stream as *mut Handle<RecvStreamInner>, HandleKind::RecvStream) };
}

/// QUIC stream id.
#[no_mangle]
pub unsafe extern "C" fn wt_recv_stream_id(stream: *mut wt_recv_stream_t) -> u64 {
    guard(0, || match recv_stream_arc(stream) {
        Ok(inner) => inner.id,
        Err(_) => 0,
    })
}

/// True when an operation is currently in flight on the stream.
#[no_mangle]
pub unsafe extern "C" fn wt_recv_stream_is_busy(stream: *mut wt_recv_stream_t) -> i32 {
    guard(0, || match recv_stream_arc(stream) {
        Ok(inner) => i32::from(inner.busy.load(Ordering::Relaxed)),
        Err(_) => 0,
    })
}

/// Reads up to `capacity` bytes.
///
/// When `destination` is non-NULL the transport reads *directly* into it and
/// the caller must keep that memory alive and untouched until the completion
/// event; together with a `wt_buffer_t` this yields a zero-copy receive path.
/// When `destination` is NULL the library allocates and the completion event
/// carries the payload (`data`/`data_len`, valid until `wt_batch_free`).
///
/// Completion: `WT_OP_STREAM_READ` with `aux` = bytes read. `WT_EOF` means the
/// stream finished, `WT_OK` with `aux > 0` means data was read.
#[no_mangle]
pub unsafe extern "C" fn wt_recv_stream_read(
    stream: *mut wt_recv_stream_t,
    destination: *mut u8,
    capacity: usize,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        if capacity == 0 {
            return wt_status_t::WT_ERR_INVALID_ARG;
        }
        let inner = match recv_stream_arc(stream) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        let Some(busy) = BusyGuard::acquire(&inner.busy) else {
            return wt_status_t::WT_ERR_OP_BUSY;
        };
        let target = if destination.is_null() {
            ReadTarget::Owned(capacity)
        } else {
            ReadTarget::Raw(RawBuffer {
                ptr: destination,
                len: capacity,
            })
        };

        spawn_event_task(async move {
            let _busy = busy;
            let mut lock = inner.stream.lock().await;
            let Some(source) = lock.as_mut() else {
                return Event::error(
                    wt_op_t::WT_OP_STREAM_READ,
                    op_id,
                    wt_status_t::WT_ERR_STREAM_CLOSED,
                    "the stream was already stopped".to_owned(),
                );
            };
            match target {
                ReadTarget::Owned(length) => {
                    let mut buffer = vec![0u8; length];
                    match source.read(&mut buffer).await {
                        Ok(Some(read)) => {
                            buffer.truncate(read);
                            Event {
                                data: EventData::Owned(buffer),
                                ..Event::ok_aux(wt_op_t::WT_OP_STREAM_READ, op_id, read as u64)
                            }
                        }
                        Ok(None) => Event {
                            status: wt_status_t::WT_EOF,
                            ..Event::ok(wt_op_t::WT_OP_STREAM_READ, op_id)
                        },
                        Err(error) => Event::error(
                            wt_op_t::WT_OP_STREAM_READ,
                            op_id,
                            map_stream_read_error(&error),
                            error.to_string(),
                        )
                        .with_aux(stream_error_code_read(&error)),
                    }
                }
                ReadTarget::Raw(buffer) => {
                    match source.read(buffer.as_mut_slice()).await {
                        Ok(Some(read)) => {
                            Event::ok_aux(wt_op_t::WT_OP_STREAM_READ, op_id, read as u64)
                        }
                        Ok(None) => Event {
                            status: wt_status_t::WT_EOF,
                            ..Event::ok(wt_op_t::WT_OP_STREAM_READ, op_id)
                        },
                        Err(error) => Event::error(
                            wt_op_t::WT_OP_STREAM_READ,
                            op_id,
                            map_stream_read_error(&error),
                            error.to_string(),
                        )
                        .with_aux(stream_error_code_read(&error)),
                    }
                }
            }
        })
    })
}

/// Reads exactly `len` bytes into `destination`.
///
/// Completion: `WT_OP_STREAM_READ_EXACT`; `aux` reports how many bytes had been
/// read when the stream finished early.
#[no_mangle]
pub unsafe extern "C" fn wt_recv_stream_read_exact(
    stream: *mut wt_recv_stream_t,
    destination: *mut u8,
    len: usize,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        if destination.is_null() || len == 0 {
            return wt_status_t::WT_ERR_INVALID_ARG;
        }
        let inner = match recv_stream_arc(stream) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        let Some(busy) = BusyGuard::acquire(&inner.busy) else {
            return wt_status_t::WT_ERR_OP_BUSY;
        };
        let pointer = RawBuffer {
            ptr: destination,
            len,
        };
        spawn_event_task(async move {
            let _busy = busy;
            let mut lock = inner.stream.lock().await;
            let Some(source) = lock.as_mut() else {
                return Event::error(
                    wt_op_t::WT_OP_STREAM_READ_EXACT,
                    op_id,
                    wt_status_t::WT_ERR_STREAM_CLOSED,
                    "the stream was already stopped".to_owned(),
                );
            };
            match source.read_exact(pointer.as_mut_slice()).await {
                Ok(()) => Event::ok_aux(wt_op_t::WT_OP_STREAM_READ_EXACT, op_id, len as u64),
                Err(StreamReadExactError::FinishedEarly(read)) => Event::error(
                    wt_op_t::WT_OP_STREAM_READ_EXACT,
                    op_id,
                    wt_status_t::WT_ERR_STREAM_FINISHED_EARLY,
                    "the stream finished before all bytes were read".to_owned(),
                )
                .with_aux(read as u64),
                Err(StreamReadExactError::Read(error)) => Event::error(
                    wt_op_t::WT_OP_STREAM_READ_EXACT,
                    op_id,
                    map_stream_read_error(&error),
                    error.to_string(),
                )
                .with_aux(stream_error_code_read(&error)),
            }
        })
    })
}

/// Stops accepting data, telling the peer to stop sending (no event).
#[no_mangle]
pub unsafe extern "C" fn wt_recv_stream_stop(
    stream: *mut wt_recv_stream_t,
    error_code: u32,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match recv_stream_arc(stream) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        with_rt(|| match inner.stream.try_lock() {
            Ok(mut lock) => match lock.take() {
                Some(target) => {
                    target.stop(VarInt::from_u32(error_code));
                    wt_status_t::WT_OK
                }
                None => wt_status_t::WT_ERR_STREAM_CLOSED,
            },
            Err(_) => wt_status_t::WT_ERR_OP_BUSY,
        })
        .unwrap_or(wt_status_t::WT_ERR_NO_RUNTIME)
    })
}
