/// Layer 3 — an established WebTransport session.
///
/// A session is symmetric: both the client that opened it and the server that
/// accepted it can open streams, accept the peer's streams, exchange datagrams
/// and close the session. Everything the browser puts on `WebTransport` after
/// the handshake lives here, so it is shared by
/// [NativeWebTransport] (client) and the server's session object.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../webtransport_bindings_generated.dart' as b;
import '../api.dart';
import 'memory.dart';
import 'runtime.dart';

/// An established session on top of a `wt_connection_t`.
final class NativeSession implements WebTransport {
  NativeSession(
    this._connection, {
    this.congestionControl = WebTransportCongestionControl.defaultPolicy,
  });

  final Pointer<b.wt_connection_t> _connection;

  @override
  final WebTransportCongestionControl congestionControl;

  final Completer<void> _closed = Completer<void>();
  final StreamController<WebTransportBidirectionalStream> _incomingBi =
      StreamController<WebTransportBidirectionalStream>.broadcast();
  final StreamController<WebTransportReceiveStream> _incomingUni =
      StreamController<WebTransportReceiveStream>.broadcast();

  _NativeDatagramDuplex? _datagrams;
  bool _disposed = false;
  bool _biPumping = false;
  bool _uniPumping = false;

  /// The underlying native connection (native only).
  Pointer<b.wt_connection_t> get connection => _connection;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Future<void> get closed => _closed.future;

  /// True once the session is gone.
  bool get isClosed => _closed.isCompleted;

  @override
  WebTransportDatagramDuplexStream get datagrams =>
      _datagrams ??= _NativeDatagramDuplex(this);

  @override
  WebTransportReliabilityMode get reliability {
    if (_disposed) return WebTransportReliabilityMode.pending;
    return b.wt_connection_max_datagram_size(_connection) >= 0
        ? WebTransportReliabilityMode.supportsUnreliable
        : WebTransportReliabilityMode.reliableOnly;
  }

  /// Stable identifier for this connection.
  int get stableId => b.wt_connection_stable_id(_connection);

  /// The WebTransport session id.
  int get sessionId => b.wt_connection_session_id(_connection);

  /// Peer UDP port.
  int get remotePort => b.wt_connection_remote_port(_connection);

  /// Peer IP address.
  String get remoteAddress {
    final buffer = calloc<Char>(64);
    final length = calloc<Size>()..value = 64;
    try {
      if (b.wt_connection_remote_ip(_connection, buffer, length) !=
          b.wt_status_t.WT_OK) {
        return '';
      }
      return buffer.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buffer);
      calloc.free(length);
    }
  }

  /// Smoothed round-trip time.
  Duration get rtt =>
      Duration(microseconds: b.wt_connection_rtt_us(_connection));

  @override
  Stream<WebTransportBidirectionalStream> get incomingBidirectionalStreams {
    _pumpIncomingBi();
    return _incomingBi.stream;
  }

  @override
  Stream<WebTransportReceiveStream> get incomingUnidirectionalStreams {
    _pumpIncomingUni();
    return _incomingUni.stream;
  }

  @override
  Future<WebTransportBidirectionalStream> createBidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]) async {
    _ensureAlive();
    final event = await nativeRuntime.oneShot(
      'wt_connection_open_bi',
      (opId) => b.wt_connection_open_bi(_connection, opId),
    );
    if (!event.isOk) throw event.exception('createBidirectionalStream');
    final send = NativeSendStream(event.handle.cast());
    send.sendOrder = options?.sendOrder;
    return _NativeBidirectionalStream(
      NativeReceiveStream(event.handle2.cast()),
      send,
    );
  }

  @override
  Future<WebTransportSendStream> createUnidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]) async {
    _ensureAlive();
    final event = await nativeRuntime.oneShot(
      'wt_connection_open_uni',
      (opId) => b.wt_connection_open_uni(_connection, opId),
    );
    if (!event.isOk) throw event.exception('createUnidirectionalStream');
    final send = NativeSendStream(event.handle.cast());
    send.sendOrder = options?.sendOrder;
    return send;
  }

  @override
  Future<void> close([WebTransportCloseInfo? closeInfo]) async {
    if (_disposed) return;
    final info = closeInfo ?? const WebTransportCloseInfo();
    final reason = info.reason;
    final pointer = reason.isEmpty ? nullptr : calloc<Uint8>(reason.length);
    if (pointer != nullptr) {
      pointer.asTypedList(reason.length).setAll(0, reason.codeUnits);
    }
    try {
      checkStatus(
        b.wt_connection_close(
          _connection,
          info.closeCode,
          pointer,
          pointer == nullptr ? 0 : reason.length,
        ),
        'wt_connection_close',
      );
    } finally {
      if (pointer != nullptr) calloc.free(pointer);
    }
    completeClosed();
  }

  @override
  Future<WebTransportStats> getStats() async {
    final micros = b.wt_connection_rtt_us(_connection);
    return WebTransportStats(
      timestamp: Duration(microseconds: micros),
      minRtt: Duration(microseconds: micros),
      smoothedRtt: Duration(microseconds: micros),
    );
  }

  /// Marks the session as closed.
  ///
  /// Incoming stream sources are *closed* rather than failed: once the session
  /// is gone there are no more streams to deliver, which is what the browser
  /// does with the corresponding `ReadableStream`s.
  void completeClosed() {
    if (!_closed.isCompleted) _closed.complete();
    if (!_incomingBi.isClosed) _incomingBi.close();
    if (!_incomingUni.isClosed) _incomingUni.close();
    _datagrams?.dispose();
  }

  /// Releases the native handle and every stream still owned by this session.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _datagrams?.dispose();
    _datagrams = null;
    if (!_incomingBi.isClosed) _incomingBi.close();
    if (!_incomingUni.isClosed) _incomingUni.close();
    b.wt_connection_free(_connection);
    completeClosed();
  }

  void _ensureAlive() {
    if (_disposed) {
      throw WebTransportException(
        b.wt_status_t.WT_ERR_NOT_CONNECTED.value,
        'the session is closed',
      );
    }
  }

  /// Reports a failure on an incoming source, or ends it when the session is
  /// simply gone.
  ///
  /// "Gone" covers both an explicit close and the errors the transport reports
  /// once the peer went away, which is what a `ReadableStream` does in the
  /// browser: it closes instead of failing.
  void _failIncoming(
    StreamController<Object?> controller,
    WebTransportException error,
  ) {
    if (error.isClosed || _closed.isCompleted || _disposed) {
      controller.close();
    } else {
      controller.addError(error);
      controller.close();
    }
  }

  /// Watches the native connection and completes [closed] when it goes away.
  void watchClosed() {
    unawaited(
      nativeRuntime
          .oneShot(
            'wt_connection_closed',
            (opId) => b.wt_connection_closed(_connection, opId),
          )
          .then((_) => completeClosed(), onError: (_) => completeClosed()),
    );
  }

  void _pumpIncomingBi() {
    if (_biPumping || _disposed) return;
    _biPumping = true;
    void pump() {
      if (_disposed || _incomingBi.isClosed) {
        _biPumping = false;
        return;
      }
      final opId = nativeRuntime.register((event) {
        if (!event.isOk) {
          _biPumping = false;
          if (!_incomingBi.isClosed) {
            _failIncoming(
              _incomingBi,
              event.exception('incomingBidirectionalStreams'),
            );
          }
          return;
        }
        if (!_incomingBi.isClosed) {
          _incomingBi.add(
            _NativeBidirectionalStream(
              NativeReceiveStream(event.handle2.cast()),
              NativeSendStream(event.handle.cast()),
            ),
          );
        }
        pump();
      });
      final status = b.wt_connection_accept_bi(_connection, opId);
      if (status != b.wt_status_t.WT_OK) {
        nativeRuntime.cancel(opId);
        _biPumping = false;
        if (!_incomingBi.isClosed) {
          _failIncoming(
            _incomingBi,
            WebTransportException(status.value, 'accept failed'),
          );
        }
      }
    }

    pump();
  }

  void _pumpIncomingUni() {
    if (_uniPumping || _disposed) return;
    _uniPumping = true;
    void pump() {
      if (_disposed || _incomingUni.isClosed) {
        _uniPumping = false;
        return;
      }
      final opId = nativeRuntime.register((event) {
        if (!event.isOk) {
          _uniPumping = false;
          if (!_incomingUni.isClosed) {
            _failIncoming(
              _incomingUni,
              event.exception('incomingUnidirectionalStreams'),
            );
          }
          return;
        }
        if (!_incomingUni.isClosed) {
          _incomingUni.add(NativeReceiveStream(event.handle.cast()));
        }
        pump();
      });
      final status = b.wt_connection_accept_uni(_connection, opId);
      if (status != b.wt_status_t.WT_OK) {
        nativeRuntime.cancel(opId);
        _uniPumping = false;
        if (!_incomingUni.isClosed) {
          _failIncoming(
            _incomingUni,
            WebTransportException(status.value, 'accept failed'),
          );
        }
      }
    }

    pump();
  }
}

final class _NativeBidirectionalStream
    implements WebTransportBidirectionalStream {
  _NativeBidirectionalStream(this.readable, this.writable);

  @override
  final NativeReceiveStream readable;

  @override
  final NativeSendStream writable;
}

/// The writing half of a stream.
final class NativeSendStream implements WebTransportSendStream {
  NativeSendStream(this._handle);

  Pointer<b.wt_send_stream_t> _handle;
  int? _sendOrder;

  /// The underlying native handle (native only).
  Pointer<b.wt_send_stream_t> get handle => _handle;

  /// QUIC stream id.
  int get id => b.wt_send_stream_id(_handle);

  @override
  int? get sendOrder => _sendOrder;

  @override
  set sendOrder(int? value) {
    _sendOrder = value;
    if (value != null && _handle != nullptr) {
      checkStatus(
        b.wt_send_stream_set_priority(_handle, value),
        'wt_send_stream_set_priority',
      );
    }
  }

  @override
  Future<void> write(List<int> data) async {
    if (data.isEmpty) return;
    final pointer = calloc<Uint8>(data.length);
    try {
      pointer.asTypedList(data.length).setAll(0, data);
      final event = await nativeRuntime.oneShot(
        'wt_send_stream_write_all',
        (opId) =>
            b.wt_send_stream_write_all(_handle, pointer, data.length, opId),
      );
      if (!event.isOk) throw event.exception('write');
    } finally {
      // The native side copies the payload before the call returns.
      calloc.free(pointer);
    }
  }

  /// Writes a native buffer without copying it in Dart (native only).
  Future<void> writeBuffer(NativeBuffer buffer) async {
    final event = await nativeRuntime.oneShot(
      'wt_send_stream_write_all',
      (opId) =>
          b.wt_send_stream_write_all(_handle, buffer.data, buffer.length, opId),
    );
    if (!event.isOk) throw event.exception('writeBuffer');
  }

  @override
  Future<void> close() async {
    final event = await nativeRuntime.oneShot(
      'wt_send_stream_finish',
      (opId) => b.wt_send_stream_finish(_handle, opId),
    );
    if (!event.isOk) throw event.exception('close');
  }

  @override
  Future<void> abort([int errorCode = 0]) async {
    checkStatus(
      b.wt_send_stream_reset(_handle, errorCode),
      'wt_send_stream_reset',
    );
  }

  /// Releases the handle.
  void dispose() {
    if (_handle == nullptr) return;
    b.wt_send_stream_free(_handle);
    _handle = nullptr;
  }
}

/// The reading half of a stream.
final class NativeReceiveStream implements WebTransportReceiveStream {
  NativeReceiveStream(this._handle, {this.chunkSize = 64 * 1024});

  Pointer<b.wt_recv_stream_t> _handle;

  /// Maximum number of bytes requested per read by [bytes].
  final int chunkSize;

  StreamController<Uint8List>? _controller;
  bool _inFlight = false;
  bool _done = false;
  bool _cancelled = false;
  bool _subscribed = false;

  /// The underlying native handle (native only).
  Pointer<b.wt_recv_stream_t> get handle => _handle;

  /// QUIC stream id.
  int get id => b.wt_recv_stream_id(_handle);

  @override
  Stream<Uint8List> get bytes {
    var controller = _controller;
    if (controller == null) {
      controller = StreamController<Uint8List>(
        onListen: _pump,
        onResume: _pump,
        onCancel: () {
          _cancelled = true;
        },
      );
      _controller = controller;
      _pump();
    } else if (_subscribed) {
      throw StateError(
        'a WebTransport receive stream is a single-subscription stream',
      );
    }
    _subscribed = true;
    return controller.stream;
  }

  @override
  Future<Uint8List?> read() async {
    final buffer = NativeBuffer(chunkSize);
    final event = await nativeRuntime.oneShot(
      'wt_recv_stream_read',
      (opId) => b.wt_recv_stream_read(_handle, buffer.data, chunkSize, opId),
    );
    if (event.isEof) {
      buffer.free();
      return null;
    }
    if (!event.isOk) {
      buffer.free();
      throw event.exception('read');
    }
    return adoptBuffer(buffer.handle, event.aux);
  }

  /// Reads exactly [length] bytes (native only).
  Future<Uint8List> readExact(int length) async {
    final buffer = NativeBuffer(length);
    final event = await nativeRuntime.oneShot(
      'wt_recv_stream_read_exact',
      (opId) => b.wt_recv_stream_read_exact(_handle, buffer.data, length, opId),
    );
    if (!event.isOk) {
      buffer.free();
      throw event.exception('readExact');
    }
    return adoptBuffer(buffer.handle, length);
  }

  @override
  Future<void> cancel([int errorCode = 0]) async {
    _cancelled = true;
    checkStatus(
      b.wt_recv_stream_stop(_handle, errorCode),
      'wt_recv_stream_stop',
    );
    final controller = _controller;
    if (controller != null && !controller.isClosed) await controller.close();
  }

  /// Releases the handle.
  void dispose() {
    _cancelled = true;
    _controller?.close();
    _controller = null;
    if (_handle == nullptr) return;
    b.wt_recv_stream_free(_handle);
    _handle = nullptr;
  }

  void _pump() {
    final controller = _controller;
    if (controller == null ||
        _inFlight ||
        _done ||
        _cancelled ||
        controller.isPaused ||
        controller.isClosed) {
      return;
    }
    _inFlight = true;
    // A fresh buffer per read: the transport writes straight into it, and the
    // chunk handed to Dart is a view over that very memory.
    final buffer = NativeBuffer(chunkSize);
    final opId = nativeRuntime.register((event) {
      _inFlight = false;
      if (event.isEof) {
        _done = true;
        buffer.free();
        if (!controller.isClosed) controller.close();
        return;
      }
      if (!event.isOk) {
        _done = true;
        buffer.free();
        if (!controller.isClosed) {
          controller.addError(event.exception('bytes'));
          controller.close();
        }
        return;
      }
      if (!controller.isClosed) {
        controller.add(adoptBuffer(buffer.handle, event.aux));
      } else {
        buffer.free();
      }
      _pump();
    });
    final status = b.wt_recv_stream_read(_handle, buffer.data, chunkSize, opId);
    if (status != b.wt_status_t.WT_OK) {
      nativeRuntime.cancel(opId);
      _inFlight = false;
      _done = true;
      buffer.free();
      if (!controller.isClosed) {
        controller.addError(WebTransportException(status.value, 'read failed'));
        controller.close();
      }
    }
  }
}

final class _NativeDatagramDuplex implements WebTransportDatagramDuplexStream {
  _NativeDatagramDuplex(this._session);

  final NativeSession _session;
  StreamController<Uint8List>? _controller;
  bool _pumping = false;

  @override
  int get maxDatagramSize =>
      b.wt_connection_max_datagram_size(_session.connection);

  @override
  Stream<Uint8List> get readable {
    var controller = _controller;
    if (controller == null) {
      controller = StreamController<Uint8List>.broadcast(
        onListen: _pump,
        onCancel: () {
          _pumping = false;
        },
      );
      _controller = controller;
      _pump();
    }
    return controller.stream;
  }

  @override
  Future<void> write(List<int> data) async {
    final connection = _session.connection;
    final limit = b.wt_connection_max_datagram_size(connection);
    if (limit >= 0 && data.length > limit) {
      throw WebTransportException(
        b.wt_status_t.WT_ERR_DATAGRAM_TOO_LARGE.value,
        'datagram of ${data.length} bytes exceeds the $limit byte limit',
      );
    }
    final pointer = calloc<Uint8>(data.length);
    try {
      pointer.asTypedList(data.length).setAll(0, data);
      checkStatus(
        b.wt_connection_send_datagram(connection, pointer, data.length),
        'wt_connection_send_datagram',
      );
    } finally {
      // The native side copies the payload before returning.
      calloc.free(pointer);
    }
  }

  void dispose() {
    _pumping = false;
    if (_controller != null && !_controller!.isClosed) _controller!.close();
    _controller = null;
  }

  void _pump() {
    if (_pumping) return;
    _pumping = true;
    void pump() {
      final controller = _controller;
      if (!_pumping ||
          controller == null ||
          controller.isClosed ||
          controller.isPaused) {
        return;
      }
      final opId = nativeRuntime.register((event) {
        if (!event.isOk) {
          _pumping = false;
          if (!controller.isClosed) {
            final error = event.exception('datagrams');
            if (error.isClosed || _session.isClosed) {
              controller.close();
            } else {
              controller.addError(error);
            }
          }
          return;
        }
        final payload = event.data;
        if (payload != null && !controller.isClosed) controller.add(payload);
        pump();
      });
      final status = b.wt_connection_recv_datagram(_session.connection, opId);
      if (status != b.wt_status_t.WT_OK) {
        nativeRuntime.cancel(opId);
        _pumping = false;
        if (!controller.isClosed) {
          controller.addError(
            WebTransportException(status.value, 'receiveDatagram failed'),
          );
        }
      }
    }

    pump();
  }
}
