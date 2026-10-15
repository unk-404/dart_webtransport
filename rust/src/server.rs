//! Server endpoint: accepts sessions and validates them.

use core::ffi::{c_char, c_void};
use std::ffi::CString;

use tokio::sync::Mutex as AsyncMutex;
use wtransport::endpoint::endpoint_side;
use wtransport::endpoint::SessionRequest;
use wtransport::{Endpoint, VarInt};

use crate::config::{build_server_config, wt_server_config_t, ServerConfigCell};
use crate::connection::{map_connection_error, new_connection_handle};
use crate::ffi::{guard, opt_str, slice_from_raw, write_cstr_out};
use crate::handle::{handle_arc, handle_free, handle_to_void, Handle, HandleKind};
use crate::runtime::{lock, spawn_event_task, with_rt, Event, wt_op_t};
use crate::status::wt_status_t;
use crate::types::{read_headers, wt_header_t};
use wtransport::config::ServerConfig;

/// Opaque handle to a server endpoint.
#[repr(C)]
pub struct wt_server_t {
    _opaque: *mut c_void,
}

/// Opaque handle to an incoming session request.
///
/// Produced by `WT_OP_SERVER_ACCEPT`, answered with
/// `wt_session_request_accept`/`wt_session_request_forbidden`/... and released
/// with `wt_session_request_free`.
#[repr(C)]
pub struct wt_session_request_t {
    _opaque: *mut c_void,
}

/// Payload behind [`wt_server_t`].
pub(crate) struct ServerInner {
    pub(crate) endpoint: Endpoint<endpoint_side::Server>,
}

/// Request metadata snapshotted while the request is still owned by the
/// transport, so the accessors never need to lock or allocate.
pub(crate) struct SessionMeta {
    path: CString,
    authority: CString,
    origin: Option<CString>,
    user_agent: Option<CString>,
    headers: Vec<(CString, CString)>,
    remote_ip: String,
    remote_port: u16,
}

impl SessionMeta {
    fn from_request(request: &SessionRequest) -> SessionMeta {
        let mut headers: Vec<(CString, CString)> = request
            .headers()
            .iter()
            .map(|(name, value)| (crate::ffi::cstring(name), crate::ffi::cstring(value)))
            .collect();
        headers.sort_by(|left, right| left.0.as_bytes().cmp(right.0.as_bytes()));

        SessionMeta {
            path: crate::ffi::cstring(request.path()),
            authority: crate::ffi::cstring(request.authority()),
            origin: request.origin().map(crate::ffi::cstring),
            user_agent: request.user_agent().map(crate::ffi::cstring),
            headers,
            remote_ip: request.remote_address().ip().to_string(),
            remote_port: request.remote_address().port(),
        }
    }
}

/// Payload behind [`wt_session_request_t`].
pub(crate) struct SessionRequestInner {
    pub(crate) meta: SessionMeta,
    pub(crate) request: AsyncMutex<Option<SessionRequest>>,
}

/// Reads the shared server payload.
fn server_arc(server: *mut wt_server_t) -> Result<std::sync::Arc<ServerInner>, wt_status_t> {
    // SAFETY: the caller guarantees `server` is a live handle of this kind.
    unsafe { handle_arc(server as *const Handle<ServerInner>, HandleKind::Server) }
}

/// Reads the configuration state out of a server configuration handle and turns
/// it into a ready to use `wtransport::ServerConfig`.
///
/// The identity is materialised through the cached copy, so the certificate
/// digest reported by `wt_server_config_certificate_hash` and the certificate
/// the endpoint presents are always the same one.
unsafe fn read_server_config(
    config: *const wt_server_config_t,
) -> Result<ServerConfig, (wt_status_t, String)> {
    let cell = unsafe {
        handle_arc(
            config as *const Handle<ServerConfigCell>,
            HandleKind::ServerConfig,
        )
    }
    .map_err(|status| (status, "invalid server configuration handle".to_owned()))?;
    let mut guard = lock(&cell);
    build_server_config(&mut guard)
}

/// Reads the shared session-request payload.
fn request_arc(
    request: *const wt_session_request_t,
) -> Result<std::sync::Arc<SessionRequestInner>, wt_status_t> {
    // SAFETY: the caller guarantees `request` is a live handle of this kind.
    unsafe {
        handle_arc(
            request as *const Handle<SessionRequestInner>,
            HandleKind::SessionRequest,
        )
    }
}

/// Creates a server endpoint (binds a UDP socket and configures TLS).
///
/// `config` may be NULL only when defaults are meaningful; a TLS identity is
/// always required and its absence is reported through `out_status`.
#[no_mangle]
pub unsafe extern "C" fn wt_server_new(
    config: *const wt_server_config_t,
    out_status: *mut wt_status_t,
) -> *mut wt_server_t {
    guard(core::ptr::null_mut(), || {
        let write_status = |status: wt_status_t| {
            if !out_status.is_null() {
                // SAFETY: the caller passes a writable `wt_status_t`.
                unsafe { *out_status = status };
            }
        };

        let wtransport_config = match unsafe { read_server_config(config) } {
            Ok(config) => config,
            Err((status, message)) => {
                crate::runtime::emit_log(format!("webtransport: {message}"));
                write_status(status);
                return core::ptr::null_mut();
            }
        };

        let endpoint = match with_rt(|| Endpoint::server(wtransport_config)) {
            None => {
                write_status(wt_status_t::WT_ERR_NO_RUNTIME);
                return core::ptr::null_mut();
            }
            Some(Err(error)) => {
                crate::runtime::emit_log(format!(
                    "webtransport: cannot bind the server socket: {error}"
                ));
                write_status(wt_status_t::WT_ERR_IO);
                return core::ptr::null_mut();
            }
            Some(Ok(endpoint)) => endpoint,
        };

        write_status(wt_status_t::WT_OK);
        Handle::new(HandleKind::Server, ServerInner { endpoint }).cast()
    })
}

/// Releases a server handle.
#[no_mangle]
pub unsafe extern "C" fn wt_server_free(server: *mut wt_server_t) {
    unsafe { handle_free(server as *mut Handle<ServerInner>, HandleKind::Server) };
}

/// Local UDP port the server is bound to, or 0 when unknown.
#[no_mangle]
pub unsafe extern "C" fn wt_server_local_port(server: *mut wt_server_t) -> u16 {
    guard(0, || match server_arc(server) {
        Ok(inner) => inner
            .endpoint
            .local_addr()
            .map(|address| address.port())
            .unwrap_or(0),
        Err(_) => 0,
    })
}

/// Number of currently open connections on this endpoint.
#[no_mangle]
pub unsafe extern "C" fn wt_server_open_connections(server: *mut wt_server_t) -> usize {
    guard(0, || match server_arc(server) {
        Ok(inner) => inner.endpoint.open_connections(),
        Err(_) => 0,
    })
}

/// Awaits the next incoming session request.
///
/// Completion: `WT_OP_SERVER_ACCEPT` with `handle` = session request. Issue a
/// new accept after every completion to keep accepting.
#[no_mangle]
pub unsafe extern "C" fn wt_server_accept(server: *mut wt_server_t, op_id: u64) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match server_arc(server) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        spawn_event_task(async move {
            let incoming = inner.endpoint.accept().await;
            match incoming.await {
                Ok(request) => {
                    let meta = SessionMeta::from_request(&request);
                    let handle = Handle::new(
                        HandleKind::SessionRequest,
                        SessionRequestInner {
                            meta,
                            request: AsyncMutex::new(Some(request)),
                        },
                    );
                    Event::ok(wt_op_t::WT_OP_SERVER_ACCEPT, op_id)
                        .with_handle(handle_to_void(handle))
                }
                Err(error) => {
                    let (status, aux) = map_connection_error(&error);
                    Event::error(wt_op_t::WT_OP_SERVER_ACCEPT, op_id, status, error.to_string())
                        .with_aux(aux)
                }
            }
        })
    })
}

/// Reloads the TLS/transport configuration, optionally rebinding the socket.
///
/// Completion: `WT_OP_SERVER_RELOADED`.
#[no_mangle]
pub unsafe extern "C" fn wt_server_reload_config(
    server: *mut wt_server_t,
    config: *const wt_server_config_t,
    rebind: i32,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match server_arc(server) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        if config.is_null() {
            return wt_status_t::WT_ERR_INVALID_ARG;
        }
        let wtransport_config = match unsafe { read_server_config(config) } {
            Ok(config) => config,
            Err((status, message)) => {
                crate::runtime::emit_log(format!("webtransport: {message}"));
                return status;
            }
        };
        spawn_event_task(async move {
            match inner
                .endpoint
                .reload_config(wtransport_config, rebind != 0)
            {
                Ok(()) => Event::ok(wt_op_t::WT_OP_SERVER_RELOADED, op_id),
                Err(error) => Event::error(
                    wt_op_t::WT_OP_SERVER_RELOADED,
                    op_id,
                    wt_status_t::WT_ERR_IO,
                    error.to_string(),
                ),
            }
        })
    })
}

/// Closes all connections and stops accepting.
///
/// Completion: `WT_OP_SERVER_CLOSED`.
#[no_mangle]
pub unsafe extern "C" fn wt_server_close(
    server: *mut wt_server_t,
    error_code: u32,
    reason: *const u8,
    reason_len: usize,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match server_arc(server) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        // SAFETY: the caller guarantees `reason_len` readable bytes.
        let reason = unsafe { slice_from_raw(reason, reason_len) }.to_vec();
        spawn_event_task(async move {
            inner
                .endpoint
                .close(VarInt::from_u32(error_code), &reason);
            Event::ok(wt_op_t::WT_OP_SERVER_CLOSED, op_id)
        })
    })
}

// ---------------------------------------------------------------------------
// Session request accessors
// ---------------------------------------------------------------------------

/// `:path` of the WebTransport request.
///
/// Borrowed: valid while the request handle is alive.
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_path(
    request: *const wt_session_request_t,
) -> *const c_char {
    guard(core::ptr::null(), || match request_arc(request) {
        Ok(inner) => inner.meta.path.as_ptr(),
        Err(_) => core::ptr::null(),
    })
}

/// `:authority` of the request (borrowed).
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_authority(
    request: *const wt_session_request_t,
) -> *const c_char {
    guard(core::ptr::null(), || match request_arc(request) {
        Ok(inner) => inner.meta.authority.as_ptr(),
        Err(_) => core::ptr::null(),
    })
}

/// `origin` header, or NULL when absent (borrowed).
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_origin(
    request: *const wt_session_request_t,
) -> *const c_char {
    guard(core::ptr::null(), || match request_arc(request) {
        Ok(inner) => inner
            .meta
            .origin
            .as_ref()
            .map_or(core::ptr::null(), |value| value.as_ptr()),
        Err(_) => core::ptr::null(),
    })
}

/// `user-agent` header, or NULL when absent (borrowed).
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_user_agent(
    request: *const wt_session_request_t,
) -> *const c_char {
    guard(core::ptr::null(), || match request_arc(request) {
        Ok(inner) => inner
            .meta
            .user_agent
            .as_ref()
            .map_or(core::ptr::null(), |value| value.as_ptr()),
        Err(_) => core::ptr::null(),
    })
}

/// Number of request headers.
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_header_count(
    request: *const wt_session_request_t,
) -> usize {
    guard(0, || match request_arc(request) {
        Ok(inner) => inner.meta.headers.len(),
        Err(_) => 0,
    })
}

/// Reads header `index` (0-based, sorted by name).
///
/// `out_name` and `out_value` receive borrowed pointers; either may be NULL but
/// not both.
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_header_at(
    request: *const wt_session_request_t,
    index: usize,
    out_name: *mut *const c_char,
    out_value: *mut *const c_char,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        if out_name.is_null() && out_value.is_null() {
            return wt_status_t::WT_ERR_INVALID_ARG;
        }
        let inner = match request_arc(request) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        let Some(entry) = inner.meta.headers.get(index) else {
            return wt_status_t::WT_ERR_INVALID_ARG;
        };
        if !out_name.is_null() {
            // SAFETY: the caller passes a writable pointer.
            unsafe { *out_name = entry.0.as_ptr() };
        }
        if !out_value.is_null() {
            // SAFETY: the caller passes a writable pointer.
            unsafe { *out_value = entry.1.as_ptr() };
        }
        wt_status_t::WT_OK
    })
}

/// Looks up a header by (case-insensitive) name; NULL when absent.
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_header(
    request: *const wt_session_request_t,
    name: *const c_char,
) -> *const c_char {
    guard(core::ptr::null(), || {
        let Some(name) = (unsafe { opt_str(name) }) else {
            return core::ptr::null();
        };
        let inner = match request_arc(request) {
            Ok(inner) => inner,
            Err(_) => return core::ptr::null(),
        };
        inner
            .meta
            .headers
            .iter()
            .find(|(header, _)| header.to_bytes().eq_ignore_ascii_case(name.as_bytes()))
            .map_or(core::ptr::null(), |(_, value)| value.as_ptr())
    })
}

/// Peer UDP port.
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_remote_port(
    request: *const wt_session_request_t,
) -> u16 {
    guard(0, || match request_arc(request) {
        Ok(inner) => inner.meta.remote_port,
        Err(_) => 0,
    })
}

/// Writes the peer IP as a NUL-terminated string into `buffer`.
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_remote_ip(
    request: *const wt_session_request_t,
    buffer: *mut c_char,
    len: *mut usize,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match request_arc(request) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        // SAFETY: the caller guarantees `buffer`/`len` are usable as documented.
        unsafe { write_cstr_out(&inner.meta.remote_ip, buffer, len) }
    })
}

/// Accepts the session.
///
/// `headers` may be NULL and carries `count` response headers.
/// Completion: `WT_OP_SESSION_ACCEPT` with `handle` = new connection. The
/// request handle is consumed; release it with `wt_session_request_free`.
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_accept(
    request: *mut wt_session_request_t,
    headers: *const wt_header_t,
    count: usize,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let extra = match unsafe { read_headers(headers, count) } {
            Some(entries) => entries,
            None => return wt_status_t::WT_ERR_INVALID_ARG,
        };
        let inner = match request_arc(request) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        spawn_event_task(async move {
            let taken = inner.request.lock().await.take();
            let Some(request) = taken else {
                return Event::error(
                    wt_op_t::WT_OP_SESSION_ACCEPT,
                    op_id,
                    wt_status_t::WT_ERR_INVALID_HANDLE,
                    "the session request was already answered".to_owned(),
                );
            };
            match request.accept_with_headers(extra).await {
                Ok(connection) => Event::ok(wt_op_t::WT_OP_SESSION_ACCEPT, op_id)
                    .with_handle(new_connection_handle(connection)),
                Err(error) => {
                    let (status, aux) = map_connection_error(&error);
                    Event::error(
                        wt_op_t::WT_OP_SESSION_ACCEPT,
                        op_id,
                        status,
                        error.to_string(),
                    )
                    .with_aux(aux)
                }
            }
        })
    })
}

/// Rejects the request with `403`.
///
/// Completion: `WT_OP_SESSION_REJECT`.
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_forbidden(
    request: *mut wt_session_request_t,
    op_id: u64,
) -> wt_status_t {
    reject(request, op_id, RejectKind::Forbidden)
}

/// Rejects the request with `404`. Completion: `WT_OP_SESSION_REJECT`.
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_not_found(
    request: *mut wt_session_request_t,
    op_id: u64,
) -> wt_status_t {
    reject(request, op_id, RejectKind::NotFound)
}

/// Rejects the request with `429`. Completion: `WT_OP_SESSION_REJECT`.
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_too_many_requests(
    request: *mut wt_session_request_t,
    op_id: u64,
) -> wt_status_t {
    reject(request, op_id, RejectKind::TooManyRequests)
}

/// Releases a session request handle without answering it.
#[no_mangle]
pub unsafe extern "C" fn wt_session_request_free(request: *mut wt_session_request_t) {
    unsafe {
        handle_free(
            request as *mut Handle<SessionRequestInner>,
            HandleKind::SessionRequest,
        )
    };
}

/// Which rejection to send.
enum RejectKind {
    Forbidden,
    NotFound,
    TooManyRequests,
}

/// Shared implementation of the three rejection helpers.
fn reject(
    request: *mut wt_session_request_t,
    op_id: u64,
    kind: RejectKind,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match request_arc(request) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        spawn_event_task(async move {
            let taken = inner.request.lock().await.take();
            let Some(request) = taken else {
                return Event::error(
                    wt_op_t::WT_OP_SESSION_REJECT,
                    op_id,
                    wt_status_t::WT_ERR_INVALID_HANDLE,
                    "the session request was already answered".to_owned(),
                );
            };
            match kind {
                RejectKind::Forbidden => request.forbidden().await,
                RejectKind::NotFound => request.not_found().await,
                RejectKind::TooManyRequests => request.too_many_requests().await,
            }
            Event::ok(wt_op_t::WT_OP_SESSION_REJECT, op_id)
        })
    })
}
