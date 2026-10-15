/// Server side of the native implementation.
///
/// This is deliberately *not* part of the portable client API: browsers cannot
/// listen for WebTransport sessions, so a server only exists on the native
/// backend. It is exported from
/// `package:webtransport/webtransport_ffi.dart`.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../webtransport_bindings_generated.dart' as b;
import '../api.dart';
import 'memory.dart';
import 'runtime.dart';
import 'session.dart';

/// How the server obtains its TLS identity.
sealed class WebTransportServerIdentity {
  const WebTransportServerIdentity();
}

/// A self-signed certificate generated in memory.
final class WebTransportSelfSignedIdentity extends WebTransportServerIdentity {
  const WebTransportSelfSignedIdentity(this.subjectAltNames);

  /// Hostnames and/or IP addresses the certificate is valid for.
  final List<String> subjectAltNames;
}

/// PEM encoded files on disk.
final class WebTransportPemFileIdentity extends WebTransportServerIdentity {
  const WebTransportPemFileIdentity({
    required this.certificatePath,
    required this.privateKeyPath,
  });

  final String certificatePath;
  final String privateKeyPath;
}

/// PEM encoded material held in memory.
final class WebTransportPemIdentity extends WebTransportServerIdentity {
  const WebTransportPemIdentity({
    required this.certificate,
    required this.privateKey,
  });

  final String certificate;
  final String privateKey;
}

/// DER encoded material held in memory.
final class WebTransportDerIdentity extends WebTransportServerIdentity {
  const WebTransportDerIdentity({
    required this.certificates,
    required this.privateKey,
  });

  /// Leaf first.
  final List<List<int>> certificates;

  /// PKCS#8 private key.
  final List<int> privateKey;
}

/// Configuration of a [WebTransportServer].
final class WebTransportServerConfig {
  /// Creates an empty configuration; an identity and a bind address are needed
  /// before it can be used.
  WebTransportServerConfig() : _handle = b.wt_server_config_new() {
    if (_handle == nullptr) {
      throw WebTransportException(
        b.wt_status_t.WT_ERR_IO.value,
        'could not allocate a server configuration',
      );
    }
  }

  Pointer<b.wt_server_config_t> _handle;
  bool _disposed = false;

  /// TLS identity to present to clients.
  WebTransportServerIdentity? identity;

  /// Local address to bind; `null` binds every interface (dual stack).
  String? bindAddress;

  /// Local port; `0` lets the OS pick one.
  int port = 0;

  /// Whether clients may migrate to a new address.
  bool allowMigration = true;

  /// Idle timeout; `null` keeps the library default.
  Duration? idleTimeout;

  /// Keep-alive interval; `null` disables it.
  Duration? keepAlive;

  /// The native handle, for use with the raw bindings.
  Pointer<b.wt_server_config_t> get handle => _handle;

  /// The SHA-256 digest of the identity's leaf certificate.
  ///
  /// Hand this to [WebTransportOptions.serverCertificateHashes] on the client
  /// side to trust a server that is not signed by a public CA — the portable way
  /// to connect to a self-signed server.
  List<WebTransportHash> certificateHashes() {
    final out = calloc<Uint8>(32);
    try {
      final status = b.wt_server_config_certificate_hash(_handle, out);
      if (status != b.wt_status_t.WT_OK) {
        throw WebTransportException(
          status.value,
          'the configuration has no usable identity',
          operation: 'wt_server_config_certificate_hash',
        );
      }
      return <WebTransportHash>[
        WebTransportHash(value: Uint8List.fromList(out.asTypedList(32))),
      ];
    } finally {
      calloc.free(out);
    }
  }

  /// Applies the resolved settings to the native handle.
  Pointer<b.wt_server_config_t> materialize() {
    final bind = bindAddress;
    final address = bind == null ? nullptr : toNativeString(bind);
    try {
      checkStatus(
        b.wt_server_config_set_bind_address(_handle, address, port),
        'wt_server_config_set_bind_address',
      );
    } finally {
      if (address != nullptr) freeNativeString(address);
    }

    checkStatus(
      b.wt_server_config_set_allow_migration(_handle, allowMigration ? 1 : 0),
      'wt_server_config_set_allow_migration',
    );

    final idle = idleTimeout;
    if (idle != null) {
      checkStatus(
        b.wt_server_config_set_idle_timeout_ms(_handle, idle.inMilliseconds),
        'wt_server_config_set_idle_timeout_ms',
      );
    }
    final keep = keepAlive;
    if (keep != null) {
      checkStatus(
        b.wt_server_config_set_keep_alive_ms(_handle, keep.inMilliseconds),
        'wt_server_config_set_keep_alive_ms',
      );
    }

    final identity = this.identity;
    if (identity != null) _applyIdentity(identity);
    return _handle;
  }

  /// Releases the configuration handle.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    b.wt_server_config_free(_handle);
    _handle = nullptr;
  }

  void _applyIdentity(WebTransportServerIdentity identity) {
    switch (identity) {
      case WebTransportSelfSignedIdentity():
        final names = identity.subjectAltNames;
        if (names.isEmpty) {
          throw ArgumentError(
            'at least one subject alternative name is needed',
          );
        }
        final array = calloc<Pointer<Char>>(names.length);
        final allocated = <Pointer<Char>>[];
        try {
          for (var index = 0; index < names.length; index++) {
            final name = toNativeString(names[index]);
            allocated.add(name);
            array[index] = name;
          }
          checkStatus(
            b.wt_server_config_set_self_signed(_handle, array, names.length),
            'wt_server_config_set_self_signed',
          );
        } finally {
          for (final name in allocated) {
            freeNativeString(name);
          }
          calloc.free(array);
        }
      case WebTransportPemFileIdentity():
        final certificate = toNativeString(identity.certificatePath);
        final key = toNativeString(identity.privateKeyPath);
        try {
          checkStatus(
            b.wt_server_config_set_identity_pem_files(
              _handle,
              certificate,
              key,
            ),
            'wt_server_config_set_identity_pem_files',
          );
        } finally {
          freeNativeString(certificate);
          freeNativeString(key);
        }
      case WebTransportPemIdentity():
        _callWithText(identity.certificate, (pointer, length) {
          checkStatus(
            b.wt_server_config_add_certificate_pem(
              _handle,
              pointer.cast(),
              length,
            ),
            'wt_server_config_add_certificate_pem',
          );
        });
        _callWithText(identity.privateKey, (pointer, length) {
          checkStatus(
            b.wt_server_config_set_private_key(_handle, pointer, length, 1),
            'wt_server_config_set_private_key',
          );
        });
      case WebTransportDerIdentity():
        for (final certificate in identity.certificates) {
          _callWithBytes(certificate, (pointer, length) {
            checkStatus(
              b.wt_server_config_add_certificate_der(_handle, pointer, length),
              'wt_server_config_add_certificate_der',
            );
          });
        }
        _callWithBytes(identity.privateKey, (pointer, length) {
          checkStatus(
            b.wt_server_config_set_private_key(_handle, pointer, length, 0),
            'wt_server_config_set_private_key',
          );
        });
    }
  }

  void _callWithText(String text, void Function(Pointer<Uint8>, int) body) =>
      _callWithBytes(text.codeUnits, body);

  void _callWithBytes(
    List<int> bytes,
    void Function(Pointer<Uint8>, int) body,
  ) {
    final pointer = calloc<Uint8>(bytes.length);
    try {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
      body(pointer, bytes.length);
    } finally {
      calloc.free(pointer);
    }
  }
}

/// An incoming session request that the application has to accept or reject.
final class WebTransportSessionRequest {
  WebTransportSessionRequest._(this._handle);

  final Pointer<b.wt_session_request_t> _handle;
  bool _answered = false;

  /// `:path` of the request.
  String get path => _string((handle) => b.wt_session_request_path(handle));

  /// `:authority` of the request.
  String get authority =>
      _string((handle) => b.wt_session_request_authority(handle));

  /// `origin` header, when present.
  String? get origin => _optionalString(b.wt_session_request_origin(_handle));

  /// `user-agent` header, when present.
  String? get userAgent =>
      _optionalString(b.wt_session_request_user_agent(_handle));

  /// All request headers.
  Map<String, String> get headers {
    final count = b.wt_session_request_header_count(_handle);
    final out = <String, String>{};
    final name = calloc<Pointer<Char>>();
    final value = calloc<Pointer<Char>>();
    try {
      for (var index = 0; index < count; index++) {
        if (b.wt_session_request_header_at(_handle, index, name, value) !=
            b.wt_status_t.WT_OK) {
          continue;
        }
        out[name.value.cast<Utf8>().toDartString()] = value.value
            .cast<Utf8>()
            .toDartString();
      }
    } finally {
      calloc.free(name);
      calloc.free(value);
    }
    return out;
  }

  /// Peer IP address.
  String get remoteAddress {
    final buffer = calloc<Char>(64);
    final length = calloc<Size>()..value = 64;
    try {
      if (b.wt_session_request_remote_ip(_handle, buffer, length) !=
          b.wt_status_t.WT_OK) {
        return '';
      }
      return buffer.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buffer);
      calloc.free(length);
    }
  }

  /// Peer UDP port.
  int get remotePort => b.wt_session_request_remote_port(_handle);

  /// Accepts the request, returning the server side of the session.
  Future<NativeSession> accept({Map<String, String>? headers}) async {
    if (_answered) {
      throw StateError('this session request was already answered');
    }
    _answered = true;
    final nativeHeaders = allocHeaders(headers);
    final Future<NativeEvent> event;
    try {
      event = nativeRuntime.oneShot(
        'wt_session_request_accept',
        (opId) => b.wt_session_request_accept(
          _handle,
          nativeHeaders.pointer,
          nativeHeaders.length,
          opId,
        ),
      );
    } finally {
      nativeHeaders.free();
    }
    final result = await event;
    if (!result.isOk) throw result.exception('accept');
    final session = NativeSession(result.handle.cast());
    session.watchClosed();
    return session;
  }

  /// Rejects the request.
  ///
  /// [statusCode] selects `403` (default), `404` or `429`.
  Future<void> reject({int statusCode = 403}) async {
    if (_answered) {
      throw StateError('this session request was already answered');
    }
    _answered = true;
    final event = await nativeRuntime.oneShot('wt_session_request_reject', (
      opId,
    ) {
      return switch (statusCode) {
        404 => b.wt_session_request_not_found(_handle, opId),
        429 => b.wt_session_request_too_many_requests(_handle, opId),
        _ => b.wt_session_request_forbidden(_handle, opId),
      };
    });
    if (!event.isOk) throw event.exception('reject');
  }

  /// Releases the handle without answering (the peer sees a hangup).
  void dispose() {
    b.wt_session_request_free(_handle);
    _answered = true;
  }

  String _string(Pointer<Char> Function(Pointer<b.wt_session_request_t>) read) {
    final pointer = read(_handle);
    return pointer == nullptr ? '' : pointer.cast<Utf8>().toDartString();
  }

  String? _optionalString(Pointer<Char> pointer) =>
      pointer == nullptr ? null : pointer.cast<Utf8>().toDartString();
}

/// A listening WebTransport server.
final class WebTransportServer {
  WebTransportServer._(this._handle, this.certificateHashes);

  /// Binds a server using [config].
  ///
  /// The configuration can be released afterwards; the returned server and its
  /// sessions keep working.
  static Future<WebTransportServer> bind(
    WebTransportServerConfig config,
  ) async {
    nativeRuntime.start();
    // Applies the identity and the socket settings to the native handle; the
    // certificate digest can only be read afterwards.
    config.materialize();
    final hashes = config.certificateHashes();

    final outStatus = calloc<Int>();
    Pointer<b.wt_server_t> server;
    try {
      server = b.wt_server_new(config.materialize(), outStatus);
      if (server == nullptr) {
        throw WebTransportException(
          outStatus.value,
          'could not create the server endpoint',
          operation: 'wt_server_new',
        );
      }
    } finally {
      calloc.free(outStatus);
    }
    return WebTransportServer._(server, hashes);
  }

  final Pointer<b.wt_server_t> _handle;

  /// The digest of the identity presented to clients.
  final List<WebTransportHash> certificateHashes;

  bool _disposed = false;

  /// The port the server is listening on.
  int get port => b.wt_server_local_port(_handle);

  /// Number of currently open connections.
  int get openConnections => b.wt_server_open_connections(_handle);

  /// The native handle, for use with the raw bindings.
  Pointer<b.wt_server_t> get handle => _handle;

  /// Waits for the next incoming session request.
  Future<WebTransportSessionRequest> accept() async {
    if (_disposed) {
      throw StateError('the server was disposed');
    }
    final event = await nativeRuntime.oneShot(
      'wt_server_accept',
      (opId) => b.wt_server_accept(_handle, opId),
    );
    if (!event.isOk) throw event.exception('accept');
    return WebTransportSessionRequest._(event.handle.cast());
  }

  /// Incoming session requests, one at a time.
  Stream<WebTransportSessionRequest> get requests async* {
    while (!_disposed) {
      yield await accept();
    }
  }

  /// Reloads the TLS/transport configuration, optionally rebinding the socket.
  Future<void> reload(
    WebTransportServerConfig config, {
    bool rebind = false,
  }) async {
    final event = await nativeRuntime.oneShot(
      'wt_server_reload_config',
      (opId) => b.wt_server_reload_config(
        _handle,
        config.materialize(),
        rebind ? 1 : 0,
        opId,
      ),
    );
    if (!event.isOk) throw event.exception('reload');
  }

  /// Closes every connection and stops accepting.
  Future<void> close({int closeCode = 0, String reason = ''}) async {
    final bytes = reason.isEmpty ? nullptr : calloc<Uint8>(reason.length);
    if (bytes != nullptr) {
      bytes.asTypedList(reason.length).setAll(0, reason.codeUnits);
    }
    try {
      final event = await nativeRuntime.oneShot(
        'wt_server_close',
        (opId) => b.wt_server_close(
          _handle,
          closeCode,
          bytes,
          bytes == nullptr ? 0 : reason.length,
          opId,
        ),
      );
      if (!event.isOk) throw event.exception('close');
    } finally {
      if (bytes != nullptr) calloc.free(bytes);
    }
  }

  /// Releases the native handle.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    b.wt_server_free(_handle);
  }
}
