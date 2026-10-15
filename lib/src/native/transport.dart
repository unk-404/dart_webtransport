/// Layer 3 — the in-process native client.
///
/// Connects to a WebTransport URL and hands out a [NativeSession] once the
/// handshake succeeded. Everything runs on the calling isolate but never blocks
/// it: the work happens on the native tokio runtime and completions arrive
/// through [WebTransportRuntime].
///
/// Most applications should call `createWebTransport` from
/// `package:flutter_webtransport/flutter_webtransport.dart` instead, which runs
/// this implementation inside a worker isolate.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../flutter_webtransport_bindings_generated.dart' as b;
import '../api.dart';
import 'memory.dart';
import 'runtime.dart';
import 'session.dart';

/// A WebTransport client session backed by the native code asset.
final class NativeWebTransport implements WebTransport {
  /// Starts connecting to [url].
  ///
  /// The constructor never throws; failures surface through [ready], exactly
  /// like the browser `WebTransport` constructor.
  ///
  /// [insecureSkipCertificateValidation] is a native-only escape hatch for local
  /// development; the portable way to trust a self-signed server is
  /// [WebTransportOptions.serverCertificateHashes].
  NativeWebTransport(
    this.url, [
    WebTransportOptions? options,
    this.insecureSkipCertificateValidation = false,
  ]) : options = options ?? const WebTransportOptions() {
    _ready = _open();
    unawaited(
      _ready.then<void>(
        (_) {},
        onError: (Object error) {
          if (!_closed.isCompleted) _closed.completeError(error);
        },
      ),
    );
  }

  /// The session URL.
  final String url;

  /// The options the session was created with.
  final WebTransportOptions options;

  /// Accepts any server certificate (native only, insecure).
  final bool insecureSkipCertificateValidation;

  late final Future<void> _ready;
  final Completer<void> _closed = Completer<void>();

  Pointer<b.wt_client_t> _client = nullptr;
  NativeSession? _session;
  bool _disposed = false;

  /// The established session, or `null` while connecting.
  NativeSession? get session => _session;

  @override
  Future<void> get ready => _ready;

  @override
  Future<void> get closed => _closed.future;

  @override
  WebTransportCongestionControl get congestionControl =>
      options.congestionControl;

  @override
  WebTransportReliabilityMode get reliability =>
      _session?.reliability ?? WebTransportReliabilityMode.pending;

  @override
  WebTransportDatagramDuplexStream get datagrams =>
      _DeferredDatagrams(this);

  @override
  Stream<WebTransportBidirectionalStream> get incomingBidirectionalStreams =>
      _afterReady((session) => session.incomingBidirectionalStreams);

  @override
  Stream<WebTransportReceiveStream> get incomingUnidirectionalStreams =>
      _afterReady((session) => session.incomingUnidirectionalStreams);

  @override
  Future<WebTransportBidirectionalStream> createBidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]) async {
    final session = await _established();
    return session.createBidirectionalStream(options);
  }

  @override
  Future<WebTransportSendStream> createUnidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]) async {
    final session = await _established();
    return session.createUnidirectionalStream(options);
  }

  @override
  Future<void> close([WebTransportCloseInfo? closeInfo]) async {
    final session = _session;
    if (session == null) {
      if (!_closed.isCompleted) {
        _closed.completeError(
          WebTransportException(
            b.wt_status_t.WT_ERR_NOT_CONNECTED.value,
            'the session was never established',
            operation: 'close',
          ),
        );
      }
      return;
    }
    await session.close(closeInfo);
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<WebTransportStats> getStats() async {
    final session = await _established();
    return session.getStats();
  }

  /// Releases the native handles.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _session?.dispose();
    _session = null;
    if (_client != nullptr) {
      b.wt_client_free(_client);
      _client = nullptr;
    }
    if (!_closed.isCompleted) _closed.complete();
  }

  // -- internals ------------------------------------------------------------

  Future<NativeSession> _established() async {
    await _ready;
    final session = _session;
    if (session == null) {
      throw WebTransportException(
        b.wt_status_t.WT_ERR_NOT_CONNECTED.value,
        'the session was disposed',
      );
    }
    return session;
  }

  Stream<T> _afterReady<T>(Stream<T> Function(NativeSession) open) async* {
    final session = await _established();
    yield* open(session);
  }

  Future<void> _open() async {
    nativeRuntime.start();

    final config = b.wt_client_config_new();
    if (config == nullptr) {
      throw WebTransportException(
        b.wt_status_t.WT_ERR_IO.value,
        'could not allocate a client configuration',
        operation: 'wt_client_config_new',
      );
    }

    final outStatus = calloc<Int>();
    Pointer<b.wt_client_t> client = nullptr;
    try {
      final hashes = options.serverCertificateHashes;
      if (hashes.isNotEmpty) {
        final flat = calloc<Uint8>(hashes.length * 32);
        try {
          final view = flat.asTypedList(hashes.length * 32);
          for (var index = 0; index < hashes.length; index++) {
            final digest = hashes[index].value;
            if (digest.length != 32) {
              throw ArgumentError(
                'serverCertificateHashes[$index] must be 32 bytes',
              );
            }
            view.setRange(index * 32, index * 32 + 32, digest);
          }
          checkStatus(
            b.wt_client_config_set_certificate_hashes(
              config,
              flat,
              hashes.length,
            ),
            'wt_client_config_set_certificate_hashes',
          );
        } finally {
          calloc.free(flat);
        }
      } else if (insecureSkipCertificateValidation) {
        checkStatus(
          b.wt_client_config_set_no_certificate_validation(config),
          'wt_client_config_set_no_certificate_validation',
        );
      }
      client = b.wt_client_new(config, outStatus);
      if (client == nullptr) {
        throw WebTransportException(
          outStatus.value,
          'could not create the client endpoint',
          operation: 'wt_client_new',
        );
      }
    } finally {
      // The native side copies everything it needs out of the configuration.
      b.wt_client_config_free(config);
      calloc.free(outStatus);
    }
    _client = client;

    final urlPointer = toNativeString(url);
    final NativeEvent event;
    try {
      event = await nativeRuntime.oneShot(
        'wt_client_connect',
        (opId) => b.wt_client_connect(client, urlPointer, nullptr, 0, opId),
      );
    } finally {
      // The native side copies the URL before returning.
      freeNativeString(urlPointer);
    }
    if (!event.isOk) throw event.exception('connect');

    final session = NativeSession(
      event.handle.cast(),
      congestionControl: options.congestionControl,
    );
    _session = session;
    session.watchClosed();
    unawaited(
      session.closed.then<void>((_) {
        if (!_closed.isCompleted) _closed.complete();
      }),
    );
  }
}

/// `datagrams` has to be handed out before the handshake finished; every
/// operation waits for [NativeWebTransport.ready] first.
final class _DeferredDatagrams implements WebTransportDatagramDuplexStream {
  _DeferredDatagrams(this._transport);

  final NativeWebTransport _transport;
  StreamController<Uint8List>? _controller;

  @override
  Stream<Uint8List> get readable {
    var controller = _controller;
    if (controller == null) {
      controller = StreamController<Uint8List>.broadcast();
      _controller = controller;
      unawaited(() async {
        try {
          final session = await _transport._established();
          await for (final datagram in session.datagrams.readable) {
            if (controller!.isClosed) return;
            controller.add(datagram);
          }
        } on Object catch (error, stackTrace) {
          if (!controller!.isClosed) {
            controller.addError(error, stackTrace);
          }
        }
      }());
    }
    return controller.stream;
  }

  @override
  int get maxDatagramSize => _transport.session?.datagrams.maxDatagramSize ?? -1;

  @override
  Future<void> write(List<int> data) async {
    final session = await _transport._established();
    await session.datagrams.write(data);
  }
}
