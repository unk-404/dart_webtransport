//! Client and server configuration handles.
//!
//! Both are mutable builder-like handles: the Dart layer creates one, applies
//! settings, and hands it to `wt_client_new` / `wt_server_new`. Everything is
//! validated eagerly so configuration mistakes surface at the call site instead
//! of later, during a handshake.
//!
//! The payload of a configuration handle is a `Mutex<..>` cell, so a handle can
//! safely be configured from any thread.

use core::ffi::{c_char, c_void};
use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;
use std::time::Duration;

use rustls_pki_types::pem::PemObject;
use rustls_pki_types::{CertificateDer, PrivateKeyDer};
use wtransport::tls::{Certificate, CertificateChain, PrivateKey, Sha256Digest};
use wtransport::{ClientConfig, Identity, ServerConfig};

use crate::ffi::{guard, opt_str};
use crate::handle::{handle_arc, handle_free, Handle, HandleKind};
use crate::runtime::lock;
use crate::status::wt_status_t;

/// Opaque handle to a client configuration.
#[repr(C)]
pub struct wt_client_config_t {
    _opaque: *mut c_void,
}

/// Opaque handle to a server configuration.
#[repr(C)]
pub struct wt_server_config_t {
    _opaque: *mut c_void,
}

/// How the client validates the server certificate.
#[derive(Debug, Clone)]
pub(crate) enum TrustMode {
    /// Platform root store (default).
    NativeRoots,
    /// Exactly these SHA-256 certificate digests.
    CertificateHashes(Vec<[u8; 32]>),
    /// Accept anything (insecure; tests only).
    NoValidation,
}

/// Mutable state of a client configuration.
#[derive(Debug, Clone)]
pub(crate) struct ClientConfigInner {
    pub(crate) bind_ip: Option<String>,
    pub(crate) bind_port: u16,
    /// `None` = library default, `Some(0)` = infinite.
    pub(crate) idle_timeout_ms: Option<u64>,
    pub(crate) keep_alive_ms: Option<u64>,
    pub(crate) trust: TrustMode,
}

impl Default for ClientConfigInner {
    fn default() -> Self {
        ClientConfigInner {
            bind_ip: None,
            bind_port: 0,
            idle_timeout_ms: None,
            keep_alive_ms: None,
            trust: TrustMode::NativeRoots,
        }
    }
}

/// Source of the server TLS identity.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) enum IdentitySpec {
    /// Not configured yet.
    #[default]
    None,
    /// Generates a self-signed certificate for these subject alternative names.
    SelfSigned(Vec<String>),
    /// DER certificates plus a PKCS#8 private key.
    Chain {
        certificates: Vec<Vec<u8>>,
        private_key: Option<Vec<u8>>,
    },
}

/// Mutable state of a server configuration.
#[derive(Default)]
pub(crate) struct ServerConfigInner {
    pub(crate) bind_ip: Option<String>,
    pub(crate) bind_port: u16,
    pub(crate) idle_timeout_ms: Option<u64>,
    pub(crate) keep_alive_ms: Option<u64>,
    pub(crate) allow_migration: Option<bool>,
    pub(crate) identity: IdentitySpec,
    /// Materialised identity.
    ///
    /// A self-signed identity is *generated*, so building it twice yields two
    /// different certificates. Caching it is what makes
    /// `wt_server_config_certificate_hash` describe the very certificate the
    /// endpoint will present — without it a client that pins the digest would
    /// reject the server with `UnknownIssuer`.
    identity_cache: Option<Identity>,
}

/// Shared cell behind [`wt_client_config_t`].
pub(crate) type ClientConfigCell = Mutex<ClientConfigInner>;

/// Shared cell behind [`wt_server_config_t`].
pub(crate) type ServerConfigCell = Mutex<ServerConfigInner>;

/// Error type shared by the configuration builders.
pub(crate) type ConfigError = (wt_status_t, String);

/// Parses `ip` into a socket address bound to `port`.
fn parse_socket_addr(ip: &str, port: u16) -> Result<SocketAddr, ConfigError> {
    match ip.parse::<IpAddr>() {
        Ok(address) => Ok(SocketAddr::new(address, port)),
        Err(_) => Err((
            wt_status_t::WT_ERR_INVALID_ARG,
            format!("'{ip}' is not a valid IP address"),
        )),
    }
}

/// Builds a `wtransport::ClientConfig` from the handle state.
pub(crate) fn build_client_config(
    inner: &ClientConfigInner,
) -> Result<wtransport::ClientConfig, ConfigError> {
    let builder = ClientConfig::builder();
    let builder = match &inner.bind_ip {
        None => builder.with_bind_default(),
        Some(ip) => builder.with_bind_address(parse_socket_addr(ip, inner.bind_port)?),
    };

    let builder = match &inner.trust {
        TrustMode::NativeRoots => builder.with_native_certs(),
        TrustMode::CertificateHashes(hashes) => {
            builder.with_server_certificate_hashes(hashes.iter().copied().map(Sha256Digest::new))
        }
        TrustMode::NoValidation => builder.with_no_cert_validation(),
    };

    let mut builder = builder;
    if let Some(millis) = inner.idle_timeout_ms {
        let timeout = if millis == 0 {
            None
        } else {
            Some(Duration::from_millis(millis))
        };
        builder = builder.max_idle_timeout(timeout).map_err(|_| {
            (
                wt_status_t::WT_ERR_INVALID_ARG,
                "the idle timeout is out of range".to_owned(),
            )
        })?;
    }
    if let Some(millis) = inner.keep_alive_ms {
        builder = builder.keep_alive_interval(if millis == 0 {
            None
        } else {
            Some(Duration::from_millis(millis))
        });
    }

    Ok(builder.build())
}

/// Builds a `wtransport::ServerConfig` from the handle state.
pub(crate) fn build_server_config(
    inner: &mut ServerConfigInner,
) -> Result<ServerConfig, ConfigError> {
    let identity = resolve_identity(inner)?;

    let builder = ServerConfig::builder();
    let builder = match &inner.bind_ip {
        None => builder.with_bind_default(inner.bind_port),
        Some(ip) => builder.with_bind_address(parse_socket_addr(ip, inner.bind_port)?),
    };
    let builder = builder.with_identity(identity);

    let mut builder = builder;
    if let Some(millis) = inner.idle_timeout_ms {
        let timeout = if millis == 0 {
            None
        } else {
            Some(Duration::from_millis(millis))
        };
        builder = builder.max_idle_timeout(timeout).map_err(|_| {
            (
                wt_status_t::WT_ERR_INVALID_ARG,
                "the idle timeout is out of range".to_owned(),
            )
        })?;
    }
    if let Some(millis) = inner.keep_alive_ms {
        builder = builder.keep_alive_interval(if millis == 0 {
            None
        } else {
            Some(Duration::from_millis(millis))
        });
    }
    if let Some(allow) = inner.allow_migration {
        builder = builder.allow_migration(allow);
    }

    Ok(builder.build())
}

/// Resolves the configured identity into a usable `wtransport::Identity`.
///
/// The result is cached, so repeated calls (and the certificate digest query)
/// observe the same certificate.
pub(crate) fn resolve_identity(
    inner: &mut ServerConfigInner,
) -> Result<Identity, ConfigError> {
    if inner.identity_cache.is_none() {
        inner.identity_cache = Some(build_identity(&inner.identity)?);
    }
    Ok(inner
        .identity_cache
        .as_ref()
        .expect("just populated")
        .clone_identity())
}

/// Resolves the configured identity into a usable `wtransport::Identity`.
pub(crate) fn build_identity(spec: &IdentitySpec) -> Result<Identity, ConfigError> {
    match spec {
        IdentitySpec::None => Err((
            wt_status_t::WT_ERR_CONFIG_INCOMPLETE,
            "the server has no TLS identity; call wt_server_config_set_self_signed, \
             wt_server_config_add_certificate_*/wt_server_config_set_private_key, or \
             wt_server_config_set_identity_pem_files"
                .to_owned(),
        )),
        IdentitySpec::SelfSigned(names) => {
            if names.is_empty() {
                return Err((
                    wt_status_t::WT_ERR_INVALID_ARG,
                    "at least one subject alternative name is required".to_owned(),
                ));
            }
            Identity::self_signed(names.iter().map(String::as_str)).map_err(|error| {
                (
                    wt_status_t::WT_ERR_TLS_CONFIG,
                    format!("invalid subject alternative name: {error}"),
                )
            })
        }
        IdentitySpec::Chain {
            certificates,
            private_key,
        } => {
            let Some(key) = private_key else {
                return Err((
                    wt_status_t::WT_ERR_CONFIG_INCOMPLETE,
                    "the identity has certificates but no private key".to_owned(),
                ));
            };
            if certificates.is_empty() {
                return Err((
                    wt_status_t::WT_ERR_CONFIG_INCOMPLETE,
                    "the identity has a private key but no certificate".to_owned(),
                ));
            }
            let mut chain = Vec::with_capacity(certificates.len());
            for der in certificates {
                let certificate = Certificate::from_der(der.clone()).map_err(|error| {
                    (
                        wt_status_t::WT_ERR_TLS_CONFIG,
                        format!("invalid certificate: {error}"),
                    )
                })?;
                chain.push(certificate);
            }
            let key = PrivateKey::from_der_pkcs8(key.clone());
            Ok(Identity::new(CertificateChain::new(chain), key))
        }
    }
}

/// Extracts the DER payload of a PKCS#8 private key given as PEM or DER.
pub(crate) fn parse_private_key(bytes: &[u8], pem: bool) -> Result<Vec<u8>, ConfigError> {
    if !pem {
        return Ok(bytes.to_vec());
    }
    let key = PrivateKeyDer::from_pem_slice(bytes).map_err(|error| {
        (
            wt_status_t::WT_ERR_TLS_CONFIG,
            format!("cannot parse the PEM private key: {error}"),
        )
    })?;
    match key {
        PrivateKeyDer::Pkcs8(pkcs8) => Ok(pkcs8.secret_pkcs8_der().to_vec()),
        _ => Err((
            wt_status_t::WT_ERR_TLS_CONFIG,
            "the private key must be PKCS#8 encoded (a 'PRIVATE KEY' PEM block)".to_owned(),
        )),
    }
}

/// Extracts every `CERTIFICATE` section of a PEM blob as DER.
pub(crate) fn parse_certificates(bytes: &[u8]) -> Result<Vec<Vec<u8>>, ConfigError> {
    let mut certificates = Vec::new();
    for item in CertificateDer::pem_slice_iter(bytes) {
        match item {
            Ok(der) => certificates.push(der.to_vec()),
            Err(error) => {
                return Err((
                    wt_status_t::WT_ERR_TLS_CONFIG,
                    format!("cannot parse a PEM certificate: {error}"),
                ))
            }
        }
    }
    if certificates.is_empty() {
        return Err((
            wt_status_t::WT_ERR_TLS_CONFIG,
            "no CERTIFICATE block found in the PEM input".to_owned(),
        ));
    }
    Ok(certificates)
}

/// Reads the shared client configuration cell.
fn client_cell(
    config: *mut wt_client_config_t,
) -> Result<std::sync::Arc<ClientConfigCell>, wt_status_t> {
    // SAFETY: the caller guarantees `config` is a live handle of this kind.
    unsafe { handle_arc(config as *const Handle<ClientConfigCell>, HandleKind::ClientConfig) }
}

/// Reads the shared server configuration cell.
fn server_cell(
    config: *mut wt_server_config_t,
) -> Result<std::sync::Arc<ServerConfigCell>, wt_status_t> {
    // SAFETY: the caller guarantees `config` is a live handle of this kind.
    unsafe { handle_arc(config as *const Handle<ServerConfigCell>, HandleKind::ServerConfig) }
}

/// Validates that `text` parses as an IP address.
fn validate_ip(text: Option<&str>) -> wt_status_t {
    match text {
        None => wt_status_t::WT_OK,
        Some(ip) => match ip.parse::<IpAddr>() {
            Ok(_) => wt_status_t::WT_OK,
            Err(_) => wt_status_t::WT_ERR_INVALID_ARG,
        },
    }
}

/// Reads an array of `count` NUL-terminated strings.
///
/// # Safety
/// `values` must point at `count` readable `*const c_char`.
unsafe fn read_string_array(values: *const *const c_char, count: usize) -> Option<Vec<String>> {
    if values.is_null() || count == 0 {
        return None;
    }
    let mut out = Vec::with_capacity(count);
    for index in 0..count {
        // SAFETY: caller guarantees a valid array of length `count`.
        let item = unsafe { *values.add(index) };
        if item.is_null() {
            return None;
        }
        // SAFETY: caller guarantees NUL-terminated strings.
        let text = unsafe { opt_str(item) }?;
        out.push(text.to_owned());
    }
    Some(out)
}

// ---------------------------------------------------------------------------
// Client configuration
// ---------------------------------------------------------------------------

/// Creates a client configuration with defaults (dual-stack ephemeral bind,
/// platform root certificates).
#[no_mangle]
pub extern "C" fn wt_client_config_new() -> *mut wt_client_config_t {
    guard(core::ptr::null_mut(), || {
        Handle::new(
            HandleKind::ClientConfig,
            Mutex::new(ClientConfigInner::default()),
        )
        .cast()
    })
}

/// Releases a client configuration handle.
#[no_mangle]
pub unsafe extern "C" fn wt_client_config_free(config: *mut wt_client_config_t) {
    unsafe { handle_free(config as *mut Handle<ClientConfigCell>, HandleKind::ClientConfig) };
}

/// Binds the client socket to `ip`:`port`.
///
/// `ip` may be NULL to bind `INADDR_ANY`/`::` (dual stack). `port` may be 0 to
/// let the OS pick an ephemeral port.
#[no_mangle]
pub unsafe extern "C" fn wt_client_config_set_bind_address(
    config: *mut wt_client_config_t,
    ip: *const c_char,
    port: u16,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let ip = unsafe { opt_str(ip) }.map(str::to_owned);
        let status = validate_ip(ip.as_deref());
        if !status.is_success() {
            return status;
        }
        let cell = match client_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        let mut inner = lock(&cell);
        inner.bind_ip = ip;
        inner.bind_port = port;
        wt_status_t::WT_OK
    })
}

/// Sets `max_idle_timeout`; 0 means "no timeout".
#[no_mangle]
pub unsafe extern "C" fn wt_client_config_set_idle_timeout_ms(
    config: *mut wt_client_config_t,
    timeout_ms: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let cell = match client_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        lock(&cell).idle_timeout_ms = Some(timeout_ms);
        wt_status_t::WT_OK
    })
}

/// Sets the keep-alive interval; 0 disables keep-alives (the default).
#[no_mangle]
pub unsafe extern "C" fn wt_client_config_set_keep_alive_ms(
    config: *mut wt_client_config_t,
    interval_ms: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let cell = match client_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        lock(&cell).keep_alive_ms = Some(interval_ms);
        wt_status_t::WT_OK
    })
}

/// Sets a connect timeout. Reserved: accepted and currently ignored.
#[no_mangle]
pub unsafe extern "C" fn wt_client_config_set_connect_timeout_ms(
    config: *mut wt_client_config_t,
    timeout_ms: u64,
) -> wt_status_t {
    let _ = timeout_ms;
    guard(wt_status_t::WT_ERR_PANIC, || {
        match client_cell(config) {
            Ok(_) => wt_status_t::WT_OK,
            Err(status) => status,
        }
    })
}

/// Trusts the platform's native root store (the default).
#[no_mangle]
pub unsafe extern "C" fn wt_client_config_set_native_roots(
    config: *mut wt_client_config_t,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let cell = match client_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        lock(&cell).trust = TrustMode::NativeRoots;
        wt_status_t::WT_OK
    })
}

/// Trusts exactly the supplied SHA-256 certificate digests (32 bytes each),
/// mirroring the W3C `serverCertificateHashes` option.
#[no_mangle]
pub unsafe extern "C" fn wt_client_config_set_certificate_hashes(
    config: *mut wt_client_config_t,
    digests: *const u8,
    digest_count: usize,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        if digests.is_null() || digest_count == 0 {
            return wt_status_t::WT_ERR_INVALID_ARG;
        }
        // SAFETY: the caller guarantees `digest_count * 32` readable bytes.
        let raw = unsafe { core::slice::from_raw_parts(digests, digest_count * 32) };
        let hashes: Vec<[u8; 32]> = raw
            .chunks_exact(32)
            .map(|chunk| {
                let mut digest = [0u8; 32];
                digest.copy_from_slice(chunk);
                digest
            })
            .collect();
        let cell = match client_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        lock(&cell).trust = TrustMode::CertificateHashes(hashes);
        wt_status_t::WT_OK
    })
}

/// Accepts any server certificate.
///
/// Insecure; intended for local testing only. Requires the
/// `dangerous-configuration` feature.
#[no_mangle]
pub unsafe extern "C" fn wt_client_config_set_no_certificate_validation(
    config: *mut wt_client_config_t,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let cell = match client_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        lock(&cell).trust = TrustMode::NoValidation;
        wt_status_t::WT_OK
    })
}

// ---------------------------------------------------------------------------
// Server configuration
// ---------------------------------------------------------------------------

/// Creates a server configuration with defaults (dual-stack bind, no identity).
#[no_mangle]
pub extern "C" fn wt_server_config_new() -> *mut wt_server_config_t {
    guard(core::ptr::null_mut(), || {
        Handle::new(
            HandleKind::ServerConfig,
            Mutex::new(ServerConfigInner::default()),
        )
        .cast()
    })
}

/// Writes the SHA-256 digest (32 bytes) of the identity's leaf certificate.
///
/// This is the value a WebTransport *client* passes as a
/// `serverCertificateHashes` entry to connect to a server whose certificate is
/// not signed by a public CA (the W3C equivalent of pinning a self-signed
/// certificate). The identity is built on demand, so the result is available
/// before the endpoint is created.
#[no_mangle]
pub unsafe extern "C" fn wt_server_config_certificate_hash(
    config: *const wt_server_config_t,
    out: *mut u8,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        if out.is_null() {
            return wt_status_t::WT_ERR_INVALID_ARG;
        }
        let cell = match unsafe {
            handle_arc(
                config as *const Handle<ServerConfigCell>,
                HandleKind::ServerConfig,
            )
        } {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        let identity = match resolve_identity(&mut lock(&cell)) {
            Ok(identity) => identity,
            Err(error) => return report_config_error(error),
        };
        let Some(certificate) = identity.certificate_chain().as_slice().first() else {
            return report_config_error((
                wt_status_t::WT_ERR_CONFIG_INCOMPLETE,
                "the identity has no certificate".to_owned(),
            ));
        };
        let digest = certificate.hash();
        let bytes: &[u8; 32] = digest.as_ref();
        // SAFETY: the caller guarantees 32 writable bytes at `out`.
        unsafe { core::ptr::copy_nonoverlapping(bytes.as_ptr(), out, 32) };
        wt_status_t::WT_OK
    })
}

/// Releases a server configuration handle.
#[no_mangle]
pub unsafe extern "C" fn wt_server_config_free(config: *mut wt_server_config_t) {
    unsafe { handle_free(config as *mut Handle<ServerConfigCell>, HandleKind::ServerConfig) };
}

/// Binds to `ip`:`port`; `ip` may be NULL for `INADDR_ANY`/`::` (dual stack).
#[no_mangle]
pub unsafe extern "C" fn wt_server_config_set_bind_address(
    config: *mut wt_server_config_t,
    ip: *const c_char,
    port: u16,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let ip = unsafe { opt_str(ip) }.map(str::to_owned);
        let status = validate_ip(ip.as_deref());
        if !status.is_success() {
            return status;
        }
        let cell = match server_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        let mut inner = lock(&cell);
        inner.bind_ip = ip;
        inner.bind_port = port;
        wt_status_t::WT_OK
    })
}

/// Idle timeout in milliseconds; 0 disables it.
#[no_mangle]
pub unsafe extern "C" fn wt_server_config_set_idle_timeout_ms(
    config: *mut wt_server_config_t,
    timeout_ms: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let cell = match server_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        lock(&cell).idle_timeout_ms = Some(timeout_ms);
        wt_status_t::WT_OK
    })
}

/// Keep-alive interval in milliseconds; 0 disables it.
#[no_mangle]
pub unsafe extern "C" fn wt_server_config_set_keep_alive_ms(
    config: *mut wt_server_config_t,
    interval_ms: u64,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let cell = match server_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        lock(&cell).keep_alive_ms = Some(interval_ms);
        wt_status_t::WT_OK
    })
}

/// Whether clients may migrate to new addresses (default: enabled).
#[no_mangle]
pub unsafe extern "C" fn wt_server_config_set_allow_migration(
    config: *mut wt_server_config_t,
    allow: i32,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let cell = match server_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        lock(&cell).allow_migration = Some(allow != 0);
        wt_status_t::WT_OK
    })
}

/// Generates a self-signed ECDSA P-256 identity (14 day validity) for the given
/// subject alternative names.
///
/// `sans` is an array of `san_count` NUL-terminated hostnames or IP addresses.
#[no_mangle]
pub unsafe extern "C" fn wt_server_config_set_self_signed(
    config: *mut wt_server_config_t,
    sans: *const *const c_char,
    san_count: usize,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let Some(names) = (unsafe { read_string_array(sans, san_count) }) else {
            return wt_status_t::WT_ERR_INVALID_ARG;
        };
        let cell = match server_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        let mut inner = lock(&cell);
        let spec = IdentitySpec::SelfSigned(names);
        replace_identity(&mut inner, spec);
        wt_status_t::WT_OK
    })
}

/// Sets the identity from PEM files on disk.
#[no_mangle]
pub unsafe extern "C" fn wt_server_config_set_identity_pem_files(
    config: *mut wt_server_config_t,
    certificate_path: *const c_char,
    private_key_path: *const c_char,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        let (Some(certificate_path), Some(private_key_path)) = (unsafe {
            (
                opt_str(certificate_path).map(str::to_owned),
                opt_str(private_key_path).map(str::to_owned),
            )
        }) else {
            return wt_status_t::WT_ERR_INVALID_ARG;
        };

        let certificate_bytes = match std::fs::read(&certificate_path) {
            Ok(bytes) => bytes,
            Err(error) => {
                return report_config_error((
                    wt_status_t::WT_ERR_IO,
                    format!("cannot read '{certificate_path}': {error}"),
                ))
            }
        };
        let key_bytes = match std::fs::read(&private_key_path) {
            Ok(bytes) => bytes,
            Err(error) => {
                return report_config_error((
                    wt_status_t::WT_ERR_IO,
                    format!("cannot read '{private_key_path}': {error}"),
                ))
            }
        };
        let certificates = match parse_certificates(&certificate_bytes) {
            Ok(certificates) => certificates,
            Err(error) => return report_config_error(error),
        };
        let private_key = match parse_private_key(&key_bytes, true) {
            Ok(private_key) => private_key,
            Err(error) => return report_config_error(error),
        };

        let cell = match server_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        let mut inner = lock(&cell);
        let spec = IdentitySpec::Chain {
            certificates,
            private_key: Some(private_key),
        };
        replace_identity(&mut inner, spec);
        wt_status_t::WT_OK
    })
}

/// Appends one DER encoded X.509 certificate to the identity chain.
#[no_mangle]
pub unsafe extern "C" fn wt_server_config_add_certificate_der(
    config: *mut wt_server_config_t,
    der: *const u8,
    len: usize,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        if der.is_null() || len == 0 {
            return wt_status_t::WT_ERR_INVALID_ARG;
        }
        // SAFETY: caller guarantees `len` readable bytes.
        let bytes = unsafe { core::slice::from_raw_parts(der, len) }.to_vec();
        let cell = match server_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        let mut inner = lock(&cell);
        mutate_identity(&mut inner, |spec| push_certificate(spec, bytes));
        wt_status_t::WT_OK
    })
}

/// Appends every `CERTIFICATE` section found in the PEM blob to the identity chain.
#[no_mangle]
pub unsafe extern "C" fn wt_server_config_add_certificate_pem(
    config: *mut wt_server_config_t,
    pem: *const c_char,
    len: usize,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        if pem.is_null() || len == 0 {
            return wt_status_t::WT_ERR_INVALID_ARG;
        }
        // SAFETY: caller guarantees `len` readable bytes.
        let bytes = unsafe { core::slice::from_raw_parts(pem.cast::<u8>(), len) };
        let certificates = match parse_certificates(bytes) {
            Ok(certificates) => certificates,
            Err(error) => return report_config_error(error),
        };
        let cell = match server_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        let mut inner = lock(&cell);
        mutate_identity(&mut inner, |spec| {
            for certificate in certificates {
                push_certificate(spec, certificate);
            }
        });
        wt_status_t::WT_OK
    })
}

/// Sets the identity private key from a PKCS#8 encoded key.
///
/// `pem` selects between PEM decoding (non-zero) and raw DER (zero).
#[no_mangle]
pub unsafe extern "C" fn wt_server_config_set_private_key(
    config: *mut wt_server_config_t,
    key: *const u8,
    len: usize,
    pem: i32,
) -> wt_status_t {
    guard(wt_status_t::WT_ERR_PANIC, || {
        if key.is_null() || len == 0 {
            return wt_status_t::WT_ERR_INVALID_ARG;
        }
        // SAFETY: caller guarantees `len` readable bytes.
        let bytes = unsafe { core::slice::from_raw_parts(key, len) };
        let der = match parse_private_key(bytes, pem != 0) {
            Ok(der) => der,
            Err(error) => return report_config_error(error),
        };
        let cell = match server_cell(config) {
            Ok(cell) => cell,
            Err(status) => return status,
        };
        let mut inner = lock(&cell);
        mutate_identity(&mut inner, |spec| match spec {
            IdentitySpec::Chain { private_key, .. } => *private_key = Some(der),
            _ => {
                *spec = IdentitySpec::Chain {
                    certificates: Vec::new(),
                    private_key: Some(der),
                }
            }
        });
        wt_status_t::WT_OK
    })
}

/// Adds a certificate to the identity, promoting the spec to `Chain` if needed.
fn push_certificate(spec: &mut IdentitySpec, certificate: Vec<u8>) {
    match spec {
        IdentitySpec::Chain { certificates, .. } => certificates.push(certificate),
        _ => {
            *spec = IdentitySpec::Chain {
                certificates: vec![certificate],
                private_key: None,
            }
        }
    }
}

/// Installs a new identity specification, dropping the cached materialisation
/// only when the specification actually changed.
///
/// Configuration setters are applied by the binding layer every time a
/// configuration is used (`materialize()` may run several times), so this has to
/// be idempotent: otherwise the certificate digest published to clients would
/// describe a certificate the endpoint never presents.
fn replace_identity(inner: &mut ServerConfigInner, spec: IdentitySpec) {
    if inner.identity != spec {
        inner.identity = spec;
        inner.identity_cache = None;
    }
}

/// Applies `mutate` to the identity specification and invalidates the cache.
fn mutate_identity(
    inner: &mut ServerConfigInner,
    mutate: impl FnOnce(&mut IdentitySpec),
) {
    let mut spec = inner.identity.clone();
    mutate(&mut spec);
    replace_identity(inner, spec);
}

/// Reports a configuration error through the log channel and returns its status.
fn report_config_error(error: ConfigError) -> wt_status_t {
    crate::runtime::emit_log(format!("webtransport: {}", error.1));
    error.0
}
