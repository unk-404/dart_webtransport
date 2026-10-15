//! Tokio runtime, completion dispatcher and the event ABI.
//!
//! # Delivery model
//!
//! Every asynchronous operation is spawned onto the runtime and pushes exactly
//! one [`Event`] into an unbounded channel once it settles. A single dispatcher
//! task drains that channel and forwards the completions to the C callback, so:
//!
//!  * the callback is never invoked concurrently (Dart event ordering is
//!    preserved without any locking on the Dart side);
//!  * the first completion of a burst is dispatched immediately (no artificial
//!    latency) while a flood is coalesced into one callback per batch, which
//!    removes most of the per-message overhead of crossing into Dart.
//!
//! Because the intended Dart consumer uses `NativeCallable.listener` (an
//! *asynchronous* callback: the native call merely transports the pointer),
//! each callback receives an owned [`EventBatch`] that the callee releases with
//! `wt_batch_free`.

use core::ffi::{c_char, c_void};
use std::ffi::CString;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use bytes::Bytes;
use tokio::sync::mpsc;

use crate::ffi::cstring;
use crate::status::wt_status_t;

/// Default maximum number of events coalesced into one callback.
pub(crate) const DEFAULT_DISPATCH_BATCH_MAX: usize = 64;

/// Hard ceiling for `wt_runtime_config_t::dispatch_batch_max`.
const DISPATCH_BATCH_CEILING: usize = 4096;

// ---------------------------------------------------------------------------
// C types
// ---------------------------------------------------------------------------

/// Kind of work an event reports on.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum wt_op_t {
    /// No operation (never reported).
    WT_OP_NONE = 0,
    /// A diagnostic line; `message` carries the text.
    WT_OP_LOG = 1,
    /// `wt_client_connect` finished; `handle` is the new connection.
    WT_OP_CLIENT_CONNECT = 2,
    /// `wt_client_close` finished.
    WT_OP_CLIENT_CLOSED = 3,
    /// `wt_server_accept` finished; `handle` is the session request.
    WT_OP_SERVER_ACCEPT = 4,
    /// `wt_server_close` finished.
    WT_OP_SERVER_CLOSED = 5,
    /// `wt_server_reload_config` finished.
    WT_OP_SERVER_RELOADED = 6,
    /// `wt_session_request_accept` finished; `handle` is the new connection.
    WT_OP_SESSION_ACCEPT = 7,
    /// A session request was rejected.
    WT_OP_SESSION_REJECT = 8,
    /// `wt_connection_open_bi` finished; `handle` = send, `handle2` = receive.
    WT_OP_OPEN_BI = 9,
    /// `wt_connection_open_uni` finished; `handle` = send.
    WT_OP_OPEN_UNI = 10,
    /// `wt_connection_accept_bi` finished; `handle` = send, `handle2` = receive.
    WT_OP_ACCEPT_BI = 11,
    /// `wt_connection_accept_uni` finished; `handle` = receive.
    WT_OP_ACCEPT_UNI = 12,
    /// `wt_connection_recv_datagram` finished; `data`/`data_len` carry the payload.
    WT_OP_RECV_DATAGRAM = 13,
    /// `wt_send_stream_write` finished; `aux` = bytes written.
    WT_OP_STREAM_WRITE = 14,
    /// `wt_send_stream_write_all` finished; `aux` = payload length.
    WT_OP_STREAM_WRITE_ALL = 15,
    /// `wt_send_stream_finish` finished.
    WT_OP_STREAM_FINISH = 16,
    /// `wt_send_stream_stopped` finished.
    WT_OP_STREAM_STOPPED = 17,
    /// `wt_recv_stream_read` finished; `aux` = bytes read (`WT_EOF` = end of stream).
    WT_OP_STREAM_READ = 18,
    /// `wt_recv_stream_read_exact` finished.
    WT_OP_STREAM_READ_EXACT = 19,
    /// `wt_connection_closed` finished; `message` describes the reason.
    WT_OP_CONNECTION_CLOSED = 20,
}

/// One completed unit of work.
///
/// Ownership: `data` (when non-NULL) and `message` belong to the enclosing
/// `wt_event_batch_t` and stay valid until `wt_batch_free`. `handle`/`handle2`
/// are transferred to the callee when non-NULL and must be released with the
/// matching `wt_*_free`.
#[repr(C)]
pub struct wt_event_t {
    /// Caller supplied correlation id (`op_id` argument of the call).
    pub op_id: u64,
    /// `wt_op_t` of the operation that produced this event.
    pub kind: wt_op_t,
    /// `wt_status_t` outcome.
    pub status: wt_status_t,
    /// Primary produced handle, or NULL.
    pub handle: *mut c_void,
    /// Secondary produced handle (receive side of a bidirectional stream), or NULL.
    pub handle2: *mut c_void,
    /// Operation specific scalar: bytes written/read, stream id, error code, ...
    pub aux: u64,
    /// Payload owned by the batch, or NULL.
    pub data: *const u8,
    /// Number of bytes at `data`.
    pub data_len: usize,
    /// NUL-terminated diagnostic string owned by the batch, or NULL.
    pub message: *const c_char,
}

/// An owned group of one or more `wt_event_t`.
///
/// Opaque: use `wt_batch_count`, `wt_batch_events` and `wt_batch_free`.
#[repr(C)]
pub struct wt_event_batch_t {
    _opaque: *mut c_void,
}

/// Event sink.
///
/// `ctx` is the pointer passed to `wt_runtime_init`. `batch` is owned by the
/// callee, which must call `wt_batch_free` when done with it. The callback is
/// invoked from a tokio worker thread, at most one thread at a time; it is
/// valid to return immediately and consume the batch later from another
/// isolate.
pub type wt_events_cb_t =
    Option<unsafe extern "C" fn(ctx: *mut c_void, batch: *const wt_event_batch_t)>;

/// Configuration for `wt_runtime_init`.
#[repr(C)]
pub struct wt_runtime_config_t {
    /// Must be set to `sizeof(wt_runtime_config_t)`; allows additive evolution.
    pub struct_size: usize,
    /// Number of tokio worker threads; `0` means "one per available CPU".
    pub worker_threads: u32,
    /// Maximum number of events coalesced into a single callback; `0` = 64.
    pub dispatch_batch_max: u32,
    /// Reserved, must be zero.
    pub reserved: [usize; 4],
}

// ---------------------------------------------------------------------------
// Event payloads
// ---------------------------------------------------------------------------

/// Payload carried by an [`Event`].
pub(crate) enum EventData {
    /// No payload.
    None,
    /// Refcounted bytes (zero-copy: the batch keeps the allocation alive).
    Bytes(Bytes),
    /// Owned byte vector.
    Owned(Vec<u8>),
}

/// A completion waiting to be delivered to the C callback.
pub(crate) struct Event {
    pub(crate) op_id: u64,
    pub(crate) kind: wt_op_t,
    pub(crate) status: wt_status_t,
    pub(crate) handle: *mut c_void,
    pub(crate) handle2: *mut c_void,
    pub(crate) aux: u64,
    pub(crate) data: EventData,
    pub(crate) message: Option<CString>,
}

impl Event {
    /// A successful completion with no handle and no payload.
    pub(crate) fn ok(kind: wt_op_t, op_id: u64) -> Event {
        Event {
            op_id,
            kind,
            status: wt_status_t::WT_OK,
            handle: ptr::null_mut(),
            handle2: ptr::null_mut(),
            aux: 0,
            data: EventData::None,
            message: None,
        }
    }

    /// A successful completion carrying `aux` (bytes transferred, stream id, ...).
    pub(crate) fn ok_aux(kind: wt_op_t, op_id: u64, aux: u64) -> Event {
        let mut event = Event::ok(kind, op_id);
        event.aux = aux;
        event
    }

    /// A failed completion with a human readable reason.
    pub(crate) fn error(kind: wt_op_t, op_id: u64, status: wt_status_t, message: String) -> Event {
        Event {
            message: Some(cstring(message)),
            status,
            ..Event::ok(kind, op_id)
        }
    }

    /// Attaches the primary produced handle.
    pub(crate) fn with_handle(mut self, handle: *mut c_void) -> Event {
        self.handle = handle;
        self
    }

    /// Attaches the secondary produced handle.
    pub(crate) fn with_handle2(mut self, handle: *mut c_void) -> Event {
        self.handle2 = handle;
        self
    }

    /// Attaches a scalar result.
    pub(crate) fn with_aux(mut self, aux: u64) -> Event {
        self.aux = aux;
        self
    }
}

// SAFETY: `handle`/`handle2` are opaque tokens produced by `Handle::new`, which
// owns an `Arc` payload that is itself `Send`. Events are handed from the tokio
// task that produced them to the single dispatcher task.
unsafe impl Send for Event {}

/// Everything the batch must keep alive while C holds the event array.
#[allow(dead_code)]
enum KeepAlive {
    Bytes(Bytes),
    Owned(Box<[u8]>),
    Text(CString),
}

/// Real payload behind the opaque [`wt_event_batch_t`] token.
struct EventBatch {
    events: Box<[wt_event_t]>,
    _keep: Vec<KeepAlive>,
}

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

struct Globals {
    runtime: tokio::runtime::Runtime,
    handle: tokio::runtime::Handle,
}

/// Locks a mutex, recovering from poisoning (a panic must not wedge the library).
#[inline]
pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

static GLOBALS: Mutex<Option<Globals>> = Mutex::new(None);
static EVENTS_TX: Mutex<Option<mpsc::UnboundedSender<Event>>> = Mutex::new(None);
static EVENT_CB: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
static EVENT_CTX: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
static RUNNING: AtomicBool = AtomicBool::new(false);
static INFLIGHT: AtomicUsize = AtomicUsize::new(0);
static IDLE_LOCK: Mutex<()> = Mutex::new(());
static IDLE_CV: Condvar = Condvar::new();

/// Handle of the running runtime, if any.
pub(crate) fn current_handle() -> Option<tokio::runtime::Handle> {
    lock(&GLOBALS).as_ref().map(|globals| globals.handle.clone())
}

/// Runs `f` with the tokio runtime context installed on the calling thread.
///
/// `quinn`'s tokio runtime adapter calls `tokio::spawn` internally, so every
/// call into `wtransport` has to happen either inside a spawned task or under
/// this guard.
pub(crate) fn with_rt<R>(f: impl FnOnce() -> R) -> Option<R> {
    let handle = current_handle()?;
    let _enter = handle.enter();
    Some(f())
}

/// Pushes an event towards the dispatcher. Drops it when the runtime is down.
pub(crate) fn emit(event: Event) {
    let sender = lock(&EVENTS_TX);
    if let Some(sender) = sender.as_ref() {
        let _ = sender.send(event);
    }
}

/// Emits a `WT_OP_LOG` diagnostic event.
pub(crate) fn emit_log(message: String) {
    emit(Event {
        op_id: 0,
        kind: wt_op_t::WT_OP_LOG,
        status: wt_status_t::WT_OK,
        handle: ptr::null_mut(),
        handle2: ptr::null_mut(),
        aux: 0,
        data: EventData::None,
        message: Some(cstring(message)),
    });
}

/// Tracks the number of in-flight operations for `wt_runtime_wait_idle`.
struct InflightGuard;

impl InflightGuard {
    fn new() -> InflightGuard {
        INFLIGHT.fetch_add(1, Ordering::AcqRel);
        InflightGuard
    }
}

impl Drop for InflightGuard {
    fn drop(&mut self) {
        if INFLIGHT.fetch_sub(1, Ordering::AcqRel) == 1 {
            let _idle = lock(&IDLE_LOCK);
            IDLE_CV.notify_all();
        }
    }
}

/// Spawns `future` on the runtime and emits the [`Event`] it resolves to.
pub(crate) fn spawn_event_task<F>(future: F) -> wt_status_t
where
    F: std::future::Future<Output = Event> + Send + 'static,
{
    let Some(handle) = current_handle() else {
        return wt_status_t::WT_ERR_NO_RUNTIME;
    };
    let guard = InflightGuard::new();
    handle.spawn(async move {
        let event = future.await;
        emit(event);
        drop(guard);
    });
    wt_status_t::WT_OK
}

// ---------------------------------------------------------------------------
// Dispatcher
// ---------------------------------------------------------------------------

async fn dispatcher(mut receiver: mpsc::UnboundedReceiver<Event>, batch_max: usize) {
    while let Some(first) = receiver.recv().await {
        let mut events = Vec::with_capacity(batch_max.min(1024));
        events.push(first);
        while events.len() < batch_max {
            match receiver.try_recv() {
                Ok(event) => events.push(event),
                Err(_) => break,
            }
        }
        dispatch_batch(events);
    }
}

fn dispatch_batch(events: Vec<Event>) {
    let callback_ptr = EVENT_CB.load(Ordering::Acquire);
    if callback_ptr.is_null() {
        return;
    }
    let context = EVENT_CTX.load(Ordering::Acquire);

    let count = events.len();
    let mut keep: Vec<KeepAlive> = Vec::with_capacity(count);
    let mut out: Vec<wt_event_t> = Vec::with_capacity(count);

    for event in events {
        let (data, data_len) = match event.data {
            EventData::None => (ptr::null(), 0usize),
            EventData::Bytes(bytes) => {
                let pointer = bytes.as_ptr();
                let len = bytes.len();
                keep.push(KeepAlive::Bytes(bytes));
                (pointer, len)
            }
            EventData::Owned(vector) => {
                let boxed = vector.into_boxed_slice();
                let pointer = boxed.as_ptr();
                let len = boxed.len();
                keep.push(KeepAlive::Owned(boxed));
                (pointer, len)
            }
        };
        let message = match event.message {
            Some(text) => {
                let pointer = text.as_ptr();
                keep.push(KeepAlive::Text(text));
                pointer
            }
            None => ptr::null(),
        };
        out.push(wt_event_t {
            op_id: event.op_id,
            kind: event.kind,
            status: event.status,
            handle: event.handle,
            handle2: event.handle2,
            aux: event.aux,
            data,
            data_len,
            message,
        });
    }

    let batch = Box::new(EventBatch {
        events: out.into_boxed_slice(),
        _keep: keep,
    });
    let token = Box::into_raw(batch) as *const wt_event_batch_t;

    // SAFETY: `callback_ptr` was stored from a `wt_events_cb_t` in
    // `wt_runtime_init`/`wt_runtime_set_callback` and is never mutated to an
    // invalid value while a callback may run.
    let callback: unsafe extern "C" fn(*mut c_void, *const wt_event_batch_t) =
        unsafe { std::mem::transmute(callback_ptr) };
    // SAFETY: the callee only stores the pointer until `wt_batch_free`.
    unsafe { callback(context, token) };
}

/// Recovers the real batch behind the opaque token.
///
/// # Safety
/// `batch` must be NULL or a value produced by [`dispatch_batch`].
#[inline]
unsafe fn batch_ref<'a>(batch: *const wt_event_batch_t) -> Option<&'a EventBatch> {
    if batch.is_null() {
        return None;
    }
    // SAFETY: the token is a `Box<EventBatch>` pointer created by `dispatch_batch`.
    Some(unsafe { &*(batch as *const EventBatch) })
}

// ---------------------------------------------------------------------------
// Exported API
// ---------------------------------------------------------------------------

/// Starts the runtime.
///
/// Returns `WT_ERR_ALREADY_INITIALIZED` when called twice, `WT_ERR_INVALID_ARG`
/// when `callback` is NULL, and `WT_ERR_IO` when the runtime cannot be built.
#[no_mangle]
pub unsafe extern "C" fn wt_runtime_init(
    config: *const wt_runtime_config_t,
    callback: wt_events_cb_t,
    ctx: *mut c_void,
) -> wt_status_t {
    crate::ffi::guard(wt_status_t::WT_ERR_PANIC, || {
        let Some(callback) = callback else {
            return wt_status_t::WT_ERR_INVALID_ARG;
        };

        let mut globals = lock(&GLOBALS);
        if globals.is_some() {
            return wt_status_t::WT_ERR_ALREADY_INITIALIZED;
        }

        let mut worker_threads = 0u32;
        let mut batch_max = DEFAULT_DISPATCH_BATCH_MAX;
        if !config.is_null() {
            // SAFETY: the caller guarantees `config` points at a valid
            // `wt_runtime_config_t` (with `struct_size` describing how much of
            // it the caller actually initialised).
            let config = unsafe { &*config };
            worker_threads = config.worker_threads;
            if config.dispatch_batch_max > 0 {
                batch_max = (config.dispatch_batch_max as usize).min(DISPATCH_BATCH_CEILING);
            }
        }

        let mut builder = tokio::runtime::Builder::new_multi_thread();
        builder.enable_all().thread_name("flutter-webtransport");
        if worker_threads > 0 {
            builder.worker_threads(worker_threads as usize);
        }
        let runtime = match builder.build() {
            Ok(runtime) => runtime,
            Err(_) => return wt_status_t::WT_ERR_IO,
        };

        let (sender, receiver) = mpsc::unbounded_channel();
        runtime.spawn(dispatcher(receiver, batch_max));
        let handle = runtime.handle().clone();

        *lock(&EVENTS_TX) = Some(sender);
        EVENT_CB.store(callback as *const () as *mut c_void, Ordering::Release);
        EVENT_CTX.store(ctx, Ordering::Release);
        *globals = Some(Globals { runtime, handle });
        RUNNING.store(true, Ordering::Release);
        wt_status_t::WT_OK
    })
}

/// Replaces the event sink and/or context.
#[no_mangle]
pub unsafe extern "C" fn wt_runtime_set_callback(
    callback: wt_events_cb_t,
    ctx: *mut c_void,
) -> wt_status_t {
    crate::ffi::guard(wt_status_t::WT_ERR_PANIC, || {
        if !RUNNING.load(Ordering::Acquire) {
            return wt_status_t::WT_ERR_NO_RUNTIME;
        }
        EVENT_CB.store(callback.map_or(ptr::null_mut(), |f| f as *const () as *mut c_void), Ordering::Release);
        EVENT_CTX.store(ctx, Ordering::Release);
        wt_status_t::WT_OK
    })
}

/// Returns 1 while the runtime is running, 0 otherwise.
#[no_mangle]
pub extern "C" fn wt_runtime_is_running() -> i32 {
    i32::from(RUNNING.load(Ordering::Acquire))
}

/// Stops the runtime without waiting for outstanding work.
///
/// Events that have not been delivered yet are dropped, and operations still
/// running are abandoned. Safe to call when the runtime was never started.
#[no_mangle]
pub extern "C" fn wt_runtime_shutdown() -> wt_status_t {
    crate::ffi::guard(wt_status_t::WT_ERR_PANIC, || {
        if !RUNNING.swap(false, Ordering::AcqRel) {
            return wt_status_t::WT_ERR_NO_RUNTIME;
        }
        // Stop the dispatcher first so no further callback can fire.
        lock(&EVENTS_TX).take();
        let globals = lock(&GLOBALS).take();
        if let Some(globals) = globals {
            globals.runtime.shutdown_background();
        }
        wt_status_t::WT_OK
    })
}

/// Blocks until every in-flight operation finished, or `timeout_ms` elapses.
#[no_mangle]
pub extern "C" fn wt_runtime_wait_idle(timeout_ms: u64) -> wt_status_t {
    crate::ffi::guard(wt_status_t::WT_ERR_PANIC, || {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        let mut idle = lock(&IDLE_LOCK);
        while INFLIGHT.load(Ordering::Acquire) > 0 {
            let now = Instant::now();
            if now >= deadline {
                return wt_status_t::WT_ERR_TIMEOUT;
            }
            let (guard, result) = IDLE_CV
                .wait_timeout(idle, deadline - now)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            idle = guard;
            if result.timed_out() && INFLIGHT.load(Ordering::Acquire) > 0 {
                return wt_status_t::WT_ERR_TIMEOUT;
            }
        }
        wt_status_t::WT_OK
    })
}

/// Number of events in `batch`.
#[no_mangle]
pub unsafe extern "C" fn wt_batch_count(batch: *const wt_event_batch_t) -> usize {
    crate::ffi::guard(0, || {
        // SAFETY: see `batch_ref`.
        unsafe { batch_ref(batch) }
            .map(|batch| batch.events.len())
            .unwrap_or(0)
    })
}

/// Pointer to the first of `wt_batch_count(batch)` contiguous `wt_event_t`.
///
/// Valid until `wt_batch_free(batch)`.
#[no_mangle]
pub unsafe extern "C" fn wt_batch_events(batch: *const wt_event_batch_t) -> *const wt_event_t {
    crate::ffi::guard(ptr::null(), || {
        // SAFETY: see `batch_ref`.
        unsafe { batch_ref(batch) }
            .map(|batch| batch.events.as_ptr())
            .unwrap_or(ptr::null())
    })
}

/// Releases a batch and everything it owns. Passing NULL is a no-op.
#[no_mangle]
pub unsafe extern "C" fn wt_batch_free(batch: *const wt_event_batch_t) {
    if batch.is_null() {
        return;
    }
    // SAFETY: the token is a `Box<EventBatch>` pointer produced by `dispatch_batch`
    // and the callee frees it exactly once.
    drop(unsafe { Box::from_raw(batch as *mut EventBatch) });
}
