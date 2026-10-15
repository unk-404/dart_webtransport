//! Status codes returned across the FFI boundary.

use core::ffi::c_char;

/// Result of an operation.
///
/// `WT_OK` and `WT_EOF` are non-negative; every error is negative. Completed
/// asynchronous operations carry a status inside their `wt_event_t`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum wt_status_t {
    /// Success.
    WT_OK = 0,
    /// Stream finished cleanly; no more data will arrive (a read returned EOF).
    WT_EOF = 1,

    /// A required pointer/argument was NULL or out of range.
    WT_ERR_INVALID_ARG = -1,
    /// The handle magic/kind did not match (use-after-free or wrong type).
    WT_ERR_INVALID_HANDLE = -2,
    /// `wt_runtime_init` has not been called successfully.
    WT_ERR_NO_RUNTIME = -3,
    /// `wt_runtime_init` was already called.
    WT_ERR_ALREADY_INITIALIZED = -4,
    /// The operation is already in flight on that stream/connection.
    WT_ERR_OP_BUSY = -5,
    /// Generic I/O failure (socket bind, accept, ...).
    WT_ERR_IO = -6,
    /// The URL passed to `wt_client_connect` is malformed or not `https`.
    WT_ERR_INVALID_URL = -7,
    /// DNS resolution failed.
    WT_ERR_DNS = -8,
    /// TLS/QUIC handshake failed.
    WT_ERR_HANDSHAKE = -9,
    /// The server rejected the WebTransport session request.
    WT_ERR_SESSION_REJECTED = -10,
    /// A reserved HTTP/3 header was supplied by the caller.
    WT_ERR_RESERVED_HEADER = -11,
    /// The connection is not usable any more.
    WT_ERR_NOT_CONNECTED = -12,
    /// `wt_send_stream_write`/`wt_send_stream_write_all` failed.
    WT_ERR_STREAM_WRITE = -13,
    /// `wt_recv_stream_read` failed.
    WT_ERR_STREAM_READ = -14,
    /// The peer reset the receive stream.
    WT_ERR_STREAM_RESET = -15,
    /// The peer stopped the send stream.
    WT_ERR_STREAM_STOPPED = -16,
    /// The send stream was already finished/reset locally.
    WT_ERR_STREAM_CLOSED = -17,
    /// `wt_recv_stream_read_exact` hit end-of-stream too early.
    WT_ERR_STREAM_FINISHED_EARLY = -18,
    /// The peer does not support receiving datagrams.
    WT_ERR_DATAGRAM_UNSUPPORTED = -19,
    /// Datagram payload exceeds what the connection can carry right now.
    WT_ERR_DATAGRAM_TOO_LARGE = -20,
    /// The endpoint was closed / is stopping.
    WT_ERR_ENDPOINT_CLOSED = -21,
    /// Certificate/key material could not be parsed.
    WT_ERR_TLS_CONFIG = -22,
    /// A blob of configuration was missing (identity, certificates, ...).
    WT_ERR_CONFIG_INCOMPLETE = -23,
    /// The requested feature was not compiled in.
    WT_ERR_UNSUPPORTED = -24,
    /// A Rust panic was caught at the FFI boundary.
    WT_ERR_PANIC = -25,
    /// Timeout (currently used by `wt_runtime_wait_idle`).
    WT_ERR_TIMEOUT = -26,
    /// Certificate hash list was malformed.
    WT_ERR_INVALID_DIGEST = -27,
}

impl wt_status_t {
    /// True for `WT_OK` and `WT_EOF`.
    #[inline]
    pub(crate) const fn is_success(self) -> bool {
        self as i32 >= 0
    }
}

/// NUL-terminated static human readable description of a status code.
#[no_mangle]
pub extern "C" fn wt_status_string(status: i32) -> *const c_char {
    let text = match status {
        0 => c"success",
        1 => c"end of stream",
        -1 => c"invalid argument",
        -2 => c"invalid handle",
        -3 => c"runtime not initialised",
        -4 => c"runtime already initialised",
        -5 => c"operation already in flight",
        -6 => c"I/O error",
        -7 => c"invalid url",
        -8 => c"dns lookup failed",
        -9 => c"handshake failed",
        -10 => c"session rejected by peer",
        -11 => c"reserved header",
        -12 => c"not connected",
        -13 => c"stream write error",
        -14 => c"stream read error",
        -15 => c"stream reset by peer",
        -16 => c"stream stopped by peer",
        -17 => c"stream closed",
        -18 => c"stream finished early",
        -19 => c"datagrams unsupported by peer",
        -20 => c"datagram too large",
        -21 => c"endpoint closed",
        -22 => c"invalid tls configuration",
        -23 => c"incomplete configuration",
        -24 => c"unsupported",
        -25 => c"panic caught at the ffi boundary",
        -26 => c"timeout",
        -27 => c"invalid certificate digest",
        _ => c"unknown status",
    };
    text.as_ptr()
}
