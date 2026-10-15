//! WebTransport connection: streams, datagrams and connection state.

use core::ffi::{c_char, c_void};

use wtransport::error::{ConnectionError, SendDatagramError, StreamOpeningError};
use wtransport::{Connection, VarInt};

use crate::ffi::{guard, slice_from_raw, slice_from_raw_mut, write_cstr_out};
use crate::handle::{handle_arc, handle_free, handle_to_void, Handle, HandleKind};
use crate::runtime::{spawn_event_task, with_rt, Event, EventData, wt_op_t};
use crate::status::wt_status_t;
use crate::stream::{
    map_stream_opening_error, new_recv_stream_handle, new_send_stream_handle,
};

/// Opaque handle to a WebTransport session.
///
/// Produced by `WT_OP_CLIENT_CONNECT` and `WT_OP_SESSION_ACCEPT` events, released
/// with `wt_connection_free`.
#[repr(C)]
pub struct wt_connection_t {
    _opaque: *mut c_void,
}

/// Payload behind [`wt_connection_t`].
pub(crate) struct ConnectionInner {
    pub(crate) connection: Connection,
}

/// Wraps a `wtransport::Connection` into an event payload handle.
pub(crate) fn new_connection_handle(connection: Connection) -> *mut c_void {
    handle_to_void(Handle::new(
        HandleKind::Connection,
        ConnectionInner { connection },
    ))
}

/// Maps a connection failure onto a status code plus an application error code.
pub(crate) fn map_connection_error(error: &ConnectionError) -> (wt_status_t, u64) {
    match error {
        ConnectionError::ApplicationClosed(close) => {
            (wt_status_t::WT_ERR_NOT_CONNECTED, close.code().into_inner())
        }
        ConnectionError::TimedOut => (wt_status_t::WT_ERR_TIMEOUT, 0),
        _ => (wt_status_t::WT_ERR_NOT_CONNECTED, 0),
    }
}

/// Maps a datagram send failure onto a status code.
pub(crate) fn map_send_datagram_error(error: SendDatagramError) -> wt_status_t {
    match error {
        SendDatagramError::NotConnected => wt_status_t::WT_ERR_NOT_CONNECTED,
        SendDatagramError::UnsupportedByPeer => wt_status_t::WT_ERR_DATAGRAM_UNSUPPORTED,
        SendDatagramError::TooLarge => wt_status_t::WT_ERR_DATAGRAM_TOO_LARGE,
    }
}

/// Builds the failure event for an operation that failed to even start a stream.
fn stream_opening_failure(op: wt_op_t, op_id: u64, error: &StreamOpeningError) -> Event {
    Event::error(
        op,
        op_id,
        map_stream_opening_error(error),
        error.to_string(),
    )
}

/// Reads the shared connection payload.
fn connection_arc(
    connection: *mut wt_connection_t,
) -> Result<std::sync::Arc<ConnectionInner>, wt_status_t> {
    // SAFETY: the caller guarantees `connection` is a live handle of this kind.
    unsafe {
        handle_arc(
            connection as *const Handle<ConnectionInner>,
            HandleKind::Connection,
        )
    }
}

/// Releases a connection handle (the session itself is not closed).
#[no_mangle]
pub unsafe extern "C" fn wt_connection_free(connection: *mut wt_connection_t) {
    unsafe { handle_free(connection as *mut Handle<ConnectionInner>, HandleKind::Connection) };
}

/// Stable per-endpoint connection identifier.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_stable_id(connection: *mut wt_connection_t) -> u64 {
    guard(0, || match connection_arc(connection) {
        Ok(inner) => inner.connection.stable_id() as u64,
        Err(_) => 0,
    })
}

/// WebTransport session id.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_session_id(connection: *mut wt_connection_t) -> u64 {
    guard(0, || match connection_arc(connection) {
        Ok(inner) => inner.connection.session_id().into_u64(),
        Err(_) => 0,
    })
}

/// Peer UDP port.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_remote_port(connection: *mut wt_connection_t) -> u16 {
    guard(0, || match connection_arc(connection) {
        Ok(inner) => inner.connection.remote_address().port(),
        Err(_) => 0,
    })
}

/// Writes the peer IP as a NUL-terminated string into `buffer`.
///
/// On success `*len` holds the number of bytes written (including the
/// terminator). When the buffer is too small, `WT_ERR_INVALID_ARG` is returned
/// and `*len` holds the required size.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_remote_ip(
    connection: *mut wt_connection_t,
    buffer: *mut c_char,
    len: *mut usize,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match connection_arc(connection) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        let address = inner.connection.remote_address().ip().to_string();
        // SAFETY: the caller guarantees `buffer`/`len` are usable as documented.
        unsafe { write_cstr_out(&address, buffer, len) }
    })
}

/// Smoothed round-trip time estimate, in microseconds.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_rtt_us(connection: *mut wt_connection_t) -> u64 {
    guard(0, || match connection_arc(connection) {
        Ok(inner) => inner.connection.rtt().as_micros() as u64,
        Err(_) => 0,
    })
}

/// Maximum datagram payload, or -1 when the peer does not support datagrams.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_max_datagram_size(connection: *mut wt_connection_t) -> i64 {
    guard(-1, || match connection_arc(connection) {
        Ok(inner) => inner
            .connection
            .max_datagram_size()
            .map(|size| size as i64)
            .unwrap_or(-1),
        Err(_) => -1,
    })
}

/// Opens a bidirectional stream.
///
/// Completion: `WT_OP_OPEN_BI` with `handle` = send stream and `handle2` =
/// receive stream.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_open_bi(
    connection: *mut wt_connection_t,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match connection_arc(connection) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        spawn_event_task(async move {
            let opening = match inner.connection.open_bi().await {
                Ok(opening) => opening,
                Err(error) => {
                    let (status, aux) = map_connection_error(&error);
                    return Event::error(
                        wt_op_t::WT_OP_OPEN_BI,
                        op_id,
                        status,
                        error.to_string(),
                    )
                    .with_aux(aux);
                }
            };
            match opening.await {
                Ok((send, recv)) => Event::ok(wt_op_t::WT_OP_OPEN_BI, op_id)
                    .with_handle(new_send_stream_handle(send))
                    .with_handle2(new_recv_stream_handle(recv)),
                Err(error) => stream_opening_failure(wt_op_t::WT_OP_OPEN_BI, op_id, &error),
            }
        })
    })
}

/// Opens a unidirectional stream.
///
/// Completion: `WT_OP_OPEN_UNI` with `handle` = send stream.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_open_uni(
    connection: *mut wt_connection_t,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match connection_arc(connection) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        spawn_event_task(async move {
            let opening = match inner.connection.open_uni().await {
                Ok(opening) => opening,
                Err(error) => {
                    let (status, aux) = map_connection_error(&error);
                    return Event::error(
                        wt_op_t::WT_OP_OPEN_UNI,
                        op_id,
                        status,
                        error.to_string(),
                    )
                    .with_aux(aux);
                }
            };
            match opening.await {
                Ok(send) => Event::ok(wt_op_t::WT_OP_OPEN_UNI, op_id)
                    .with_handle(new_send_stream_handle(send)),
                Err(error) => stream_opening_failure(wt_op_t::WT_OP_OPEN_UNI, op_id, &error),
            }
        })
    })
}

/// Accepts a peer-opened bidirectional stream.
///
/// Completion: `WT_OP_ACCEPT_BI` with `handle` = send stream and `handle2` =
/// receive stream.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_accept_bi(
    connection: *mut wt_connection_t,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match connection_arc(connection) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        spawn_event_task(async move {
            match inner.connection.accept_bi().await {
                Ok((send, recv)) => Event::ok(wt_op_t::WT_OP_ACCEPT_BI, op_id)
                    .with_handle(new_send_stream_handle(send))
                    .with_handle2(new_recv_stream_handle(recv)),
                Err(error) => {
                    let (status, aux) = map_connection_error(&error);
                    Event::error(wt_op_t::WT_OP_ACCEPT_BI, op_id, status, error.to_string())
                        .with_aux(aux)
                }
            }
        })
    })
}

/// Accepts a peer-opened unidirectional stream.
///
/// Completion: `WT_OP_ACCEPT_UNI` with `handle` = receive stream.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_accept_uni(
    connection: *mut wt_connection_t,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match connection_arc(connection) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        spawn_event_task(async move {
            match inner.connection.accept_uni().await {
                Ok(recv) => Event::ok(wt_op_t::WT_OP_ACCEPT_UNI, op_id)
                    .with_handle(new_recv_stream_handle(recv)),
                Err(error) => {
                    let (status, aux) = map_connection_error(&error);
                    Event::error(wt_op_t::WT_OP_ACCEPT_UNI, op_id, status, error.to_string())
                        .with_aux(aux)
                }
            }
        })
    })
}

/// Sends a datagram.
///
/// The payload is copied into the transport, so the caller may reuse (or free)
/// the buffer as soon as the function returns.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_send_datagram(
    connection: *mut wt_connection_t,
    payload: *const u8,
    len: usize,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match connection_arc(connection) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        // SAFETY: the caller guarantees `len` readable bytes.
        let payload = unsafe { slice_from_raw(payload, len) };
        match inner.connection.send_datagram(payload) {
            Ok(()) => wt_status_t::WT_OK,
            Err(error) => map_send_datagram_error(error),
        }
    })
}

/// Receives the next datagram.
///
/// Completion: `WT_OP_RECV_DATAGRAM` with a zero-copy `data`/`data_len` pair
/// that stays valid until `wt_batch_free`.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_recv_datagram(
    connection: *mut wt_connection_t,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match connection_arc(connection) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        spawn_event_task(async move {
            match inner.connection.receive_datagram().await {
                Ok(datagram) => {
                    let payload = datagram.payload();
                    let len = payload.len() as u64;
                    Event {
                        data: EventData::Bytes(payload),
                        ..Event::ok_aux(wt_op_t::WT_OP_RECV_DATAGRAM, op_id, len)
                    }
                }
                Err(error) => {
                    let (status, aux) = map_connection_error(&error);
                    Event::error(
                        wt_op_t::WT_OP_RECV_DATAGRAM,
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

/// Waits until the connection is closed for any reason.
///
/// Completion: `WT_OP_CONNECTION_CLOSED`; `status`/`message` describe the reason
/// and `aux` carries the application error code when available.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_closed(
    connection: *mut wt_connection_t,
    op_id: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match connection_arc(connection) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        spawn_event_task(async move {
            let error = inner.connection.closed().await;
            let (status, aux) = map_connection_error(&error);
            Event::error(
                wt_op_t::WT_OP_CONNECTION_CLOSED,
                op_id,
                status,
                error.to_string(),
            )
            .with_aux(aux)
        })
    })
}

/// Closes the connection immediately.
#[no_mangle]
pub unsafe extern "C" fn wt_connection_close(
    connection: *mut wt_connection_t,
    error_code: u32,
    reason: *const u8,
    reason_len: usize,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let inner = match connection_arc(connection) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        // SAFETY: the caller guarantees `reason_len` readable bytes.
        let reason = unsafe { slice_from_raw(reason, reason_len) };
        match with_rt(|| inner.connection.close(VarInt::from_u32(error_code), reason)) {
            Some(()) => wt_status_t::WT_OK,
            None => wt_status_t::WT_ERR_NO_RUNTIME,
        }
    })
}

/// Derives keying material from the TLS session (RFC 5705).
#[no_mangle]
pub unsafe extern "C" fn wt_connection_export_keying_material(
    connection: *mut wt_connection_t,
    out: *mut u8,
    out_len: usize,
    label: *const u8,
    label_len: usize,
    context: *const u8,
    context_len: usize,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        if out.is_null() || out_len == 0 {
            return wt_status_t::WT_ERR_INVALID_ARG;
        }
        let inner = match connection_arc(connection) {
            Ok(inner) => inner,
            Err(status) => return status,
        };
        // SAFETY: the caller guarantees `out_len` writable bytes.
        let out = unsafe { slice_from_raw_mut(out, out_len) };
        // SAFETY: the caller guarantees `label_len` readable bytes.
        let label = unsafe { slice_from_raw(label, label_len) };
        // SAFETY: the caller guarantees `context_len` readable bytes.
        let context = unsafe { slice_from_raw(context, context_len) };
        match inner.connection.export_keying_material(out, label, context) {
            Ok(()) => wt_status_t::WT_OK,
            Err(_) => wt_status_t::WT_ERR_INVALID_ARG,
        }
    })
}
