//! Client endpoint: creates sessions against a WebTransport server.

use core::ffi::{c_char, c_void};

use wtransport::endpoint::endpoint_side;
use wtransport::endpoint::ConnectOptions;
use wtransport::error::ConnectingError;
use wtransport::{Endpoint, VarInt};

use crate::config::{build_client_config, wt_client_config_t, ClientConfigCell, ClientConfigInner};
use crate::connection::new_connection_handle;
use crate::ffi::{guard, req_str, slice_from_raw};
use crate::handle::{handle_arc, handle_free, Handle, HandleKind};
use crate::runtime::{lock, spawn_event_task, with_rt, Event, wt_op_t};
use crate::status::wt_status_t;
use crate::types::{read_headers, wt_header_t};

/// Opaque handle to a client endpoint.
///
/// Created by `wt_client_new`, released with `wt_client_free`.
#[repr(C)]
pub struct wt_client_t {
    _opaque: *mut c_void,
}

/// Payload behind [`wt_client_t`].
pub(crate) struct ClientInner {
    pub(crate) endpoint: Endpoint<endpoint_side::Client>,
}

/// Maps a connection attempt failure onto a status code.
pub(crate) fn map_connecting_error(error: &ConnectingError) -> wt_status_t {
    match error {
        ConnectingError::InvalidUrl(_) => wt_status_t::WT_ERR_INVALID_URL,
        ConnectingError::DnsLookup(_) | ConnectingError::DnsNotFound => wt_status_t::WT_ERR_DNS,
        ConnectingError::ConnectionError(_) => wt_status_t::WT_ERR_HANDSHAKE,
        ConnectingError::SessionRejected => wt_status_t::WT_ERR_SESSION_REJECTED,
        ConnectingError::ReservedHeader(_) => wt_status_t::WT_ERR_RESERVED_HEADER,
        ConnectingError::EndpointStopping => wt_status_t::WT_ERR_ENDPOINT_CLOSED,
        ConnectingError::CidsExhausted => wt_status_t::WT_ERR_IO,
        ConnectingError::InvalidServerName(_) => wt_status_t::WT_ERR_HANDSHAKE,
        ConnectingError::InvalidRemoteAddress(_) => wt_status_t::WT_ERR_INVALID_URL,
    }
}

/// Reads the shared client payload.
fn client_arc(client: *mut wt_client_t) -> Result<std::sync::Arc<ClientInner>, wt_status_t> {
    // SAFETY: the caller guarantees `client` is a live handle of this kind.
    unsafe { handle_arc(client as *const Handle<ClientInner>, HandleKind::Client) }
}

/// Reads the configuration state out of a configuration handle.
unsafe fn read_client_config(config: *const wt_client_config_t) -> Result<ClientConfigInner, wt_status_t> {
    if config.is_null() {
        return Ok(ClientConfigInner::default());
    }
    // SAFETY: the caller guarantees `config` is a live configuration handle.
    let cell = unsafe {
        handle_arc(
            config as *const Handle<ClientConfigCell>,
            HandleKind::ClientConfig,
        )
    }?;
    let state = lock(&cell).clone();
    Ok(state)
}

/// Creates a client endpoint (binds a UDP socket).
///
/// `config` may be NULL for defaults. `out_status` receives the status; the
/// return value is NULL on failure.
#[no_mangle]
pub unsafe extern "C" fn wt_client_new(
    config: *const wt_client_config_t,
    out_status: *mut wt_status_t,
) -> *mut wt_client_t {
    guard(core::ptr::null_mut(), || {
        let write_status = |status: wt_status_t| {
            if !out_status.is_null() {
                // SAFETY: the caller passes a writable `wt_status_t`.
                unsafe { *out_status = status };
            }
        };

        let state = match unsafe { read_client_config(config) } {
            Ok(state) => state,
            Err(status) => {
                write_status(status);
                return core::ptr::null_mut();
            }
        };

        let wtransport_config = match build_client_config(&state) {
            Ok(config) => config,
            Err((status, message)) => {
                crate::runtime::emit_log(format!("flutter_webtransport: {message}"));
                write_status(status);
                return core::ptr::null_mut();
            }
        };

        let endpoint = match with_rt(|| Endpoint::client(wtransport_config)) {
            None => {
                write_status(wt_status_t::WT_ERR_NO_RUNTIME);
                return core::ptr::null_mut();
            }
            Some(Err(error)) => {
                crate::runtime::emit_log(format!(
                    "flutter_webtransport: cannot bind the client socket: {error}"
                ));
                write_status(wt_status_t::WT_ERR_IO);
                return core::ptr::null_mut();
            }
            Some(Ok(endpoint)) => endpoint,
        };

        write_status(wt_status_t::WT_OK);
        Handle::new(HandleKind::Client, ClientInner { endpoint }).cast()
    })
}

/// Releases a client handle (the endpoint is closed once in-flight work ends).
#[no_mangle]
pub unsafe extern "C" fn wt_client_free(client: *mut wt_client_t) {
    unsafe { handle_free(client as *mut Handle<ClientInner>, HandleKind::Client) };
}

/// Local UDP port the client is bound to, or 0 when unknown.
#[no_mangle]
pub unsafe extern "C" fn wt_client_local_port(client: *mut wt_client_t) -> u16 {
    guard(0, || match client_arc(client) {
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
pub unsafe extern "C" fn wt_client_open_connections(client: *mut wt_client_t) -> usize {
    guard(0, || match client_arc(client) {
        Ok(inner) => inner.endpoint.open_connections(),
        Err(_) => 0,
    })
}

/// Starts a WebTransport session.
///
/// `url` must be `https://host[:port]/[path]`. `headers` may be NULL and carries
/// `count` additional request headers. `op_id` is echoed back in the completion
/// event (`WT_OP_CLIENT_CONNECT` with `handle` = the new connection).
#[no_mangle]
pub unsafe extern "C" fn wt_client_connect(
    client: *mut wt_client_t,
    url: *const c_char,
    headers: *const wt_header_t,
    count: usize,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let url = match unsafe { req_str(url) } {
            Ok(url) => url.to_owned(),
            Err(status) => return status,
        };
        let extra = match unsafe { read_headers(headers, count) } {
            Some(entries) => entries,
            None => return wt_status_t::WT_ERR_INVALID_ARG,
        };
        let inner = match client_arc(client) {
            Ok(inner) => inner,
            Err(status) => return status,
        };

        let mut builder = ConnectOptions::builder(url);
        for (name, value) in extra {
            builder = builder.add_header(name, value);
        }
        let options = builder.build();

        spawn_event_task(async move {
            match inner.endpoint.connect(options).await {
                Ok(connection) => Event::ok(wt_op_t::WT_OP_CLIENT_CONNECT, op_id)
                    .with_handle(new_connection_handle(connection)),
                Err(error) => Event::error(
                    wt_op_t::WT_OP_CLIENT_CONNECT,
                    op_id,
                    map_connecting_error(&error),
                    error.to_string(),
                ),
            }
        })
    })
}

/// Closes every connection of this endpoint immediately.
///
/// Completion: `WT_OP_CLIENT_CLOSED`.
#[no_mangle]
pub unsafe extern "C" fn wt_client_close(
    client: *mut wt_client_t,
    error_code: u32,
    reason: *const u8,
    reason_len: usize,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match client_arc(client) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        // SAFETY: the caller guarantees `reason_len` readable bytes.
        let reason = unsafe { slice_from_raw(reason, reason_len) }.to_vec();
        spawn_event_task(async move {
            inner.endpoint.close(VarInt::from_u32(error_code), &reason);
            Event::ok(wt_op_t::WT_OP_CLIENT_CLOSED, op_id)
        })
    })
}
