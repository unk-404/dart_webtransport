/// Worker isolate backend.
///
/// The portable `createWebTransport` in
/// `package:flutter_webtransport/flutter_webtransport.dart` runs the native
/// implementation inside a dedicated worker isolate and hands the application a
/// proxy that speaks the same [WebTransport] interface. That gives:
///
///  * a UI isolate that never calls into `dart:ffi` at all — it only exchanges
///    messages, so no native call, no `malloc` and no decoding happens on it;
///  * real multi-threading: the tokio runtime owns its own worker threads and the
///    Dart side has its own isolate, so several sessions progress in parallel;
///  * back-pressure: reads are **pull based** (`readNext`), so a slow consumer
///    simply stops asking and QUIC flow control slows the peer down.
///
/// Chunk transfer is zero-copy. Dart isolates share the process address space,
/// so the worker sends the *address* of the native `wt_buffer_t` it read into,
/// and the receiving isolate wraps that memory in a `Uint8List` that frees the
/// handle when it is collected — no copy anywhere between QUIC and the
/// application.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import '../../flutter_webtransport_bindings_generated.dart' as b;
import '../api.dart';
import 'memory.dart';
import 'runtime.dart';
import 'session.dart';
import 'transport.dart';

/// Default chunk size requested by `bytes` on a proxied receive stream.
const int _defaultChunkSize = 64 * 1024;

// ---------------------------------------------------------------------------
// Main isolate: spawner and proxies
// ---------------------------------------------------------------------------

/// Spawns and owns a worker isolate running the native implementation.
final class WebTransportWorker {
  WebTransportWorker._(this._isolate, this._toWorker);

  /// Spawns the worker.
  static Future<WebTransportWorker> spawn({
    int workerThreads = 0,
    int dispatchBatchMax = 64,
    int chunkSize = _defaultChunkSize,
  }) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerEntry,
      _WorkerBootstrap(
        ready.sendPort,
        workerThreads: workerThreads,
        dispatchBatchMax: dispatchBatchMax,
        chunkSize: chunkSize,
      ),
      debugName: 'flutter_webtransport',
      errorsAreFatal: false,
    );
    final first = await ready.first;
    ready.close();
    if (first is! SendPort) {
      isolate.kill(priority: Isolate.immediate);
      throw StateError('the webtransport worker failed to start: $first');
    }
    final worker = WebTransportWorker._(isolate, first);
    worker._receive.listen(worker._onMessage);
    return worker;
  }

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _receive = ReceivePort();

  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  final Map<int, _ProxySession> _sessions = <int, _ProxySession>{};
  int _nextRequestId = 1;
  bool _disposed = false;

  /// Opens a session in the worker isolate.
  Future<WebTransport> connect(String url, [WebTransportOptions? options]) async {
    final op = options ?? const WebTransportOptions();
    final response = await _command(<String, Object?>{
      'cmd': 'connect',
      'url': url,
      'hashes': <Object?>[
        for (final hash in op.serverCertificateHashes)
          <Object?>[hash.algorithm, Uint8List.fromList(hash.value)],
      ],
      'insecure': _insecureRequested,
      'congestion': op.congestionControl.wireName,
    });
    if (response['error'] case final String error) {
      throw WebTransportError(
        source: WebTransportErrorSource.session,
        message: error,
      );
    }
    final sessionId = response['session']! as int;
    final proxy = _ProxySession(this, sessionId, op);
    _sessions[sessionId] = proxy;
    return proxy;
  }

  /// Set by [connectInsecure] to allow a self-signed server certificate.
  bool _insecureRequested = false;

  /// Opens a session in the worker isolate without certificate validation.
  ///
  /// Native only; insecure, for local development.
  Future<WebTransport> connectInsecure(
    String url, [
    WebTransportOptions? options,
  ]) {
    _insecureRequested = true;
    return connect(url, options).whenComplete(() => _insecureRequested = false);
  }

  /// Stops the worker isolate and every session it owns.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _toWorker.send(<String, Object?>{'cmd': 'shutdown'});
    _receive.close();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('the webtransport worker is shutting down'),
        );
      }
    }
    _pending.clear();
    // Give the worker a moment to release its native handles before killing it.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  Future<Map<String, Object?>> _command(Map<String, Object?> message) {
    if (_disposed) {
      return Future<Map<String, Object?>>.error(
        StateError('the webtransport worker was disposed'),
      );
    }
    final id = _nextRequestId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _toWorker.send(<String, Object?>{...message, 'id': id});
    return completer.future;
  }

  void _onMessage(dynamic message) {
    if (message is! Map) return;
    final event = message['ev'] as String?;
    switch (event) {
      case 'response':
      case 'readResult':
      case 'datagramResult':
        final completer = _pending.remove(message['id'] as int);
        completer?.complete(message.cast<String, Object?>());
      case 'bi':
        _sessions[message['session']]?._onIncomingBi(
          message.cast<String, Object?>(),
        );
      case 'uni':
        _sessions[message['session']]?._onIncomingUni(
          message.cast<String, Object?>(),
        );
      case 'closed':
        _sessions[message['session']]?._markClosed();
      case 'error':
        for (final completer in _pending.values) {
          if (!completer.isCompleted) {
            completer.completeError(StateError('${message['message']}'));
          }
        }
        _pending.clear();
    }
  }
}

/// Identity of the address space shared by both isolates.
final Finalizer<int> _adoptedBufferReaper = Finalizer<int>(
  (handle) => b.wt_buffer_free(Pointer<b.wt_buffer_t>.fromAddress(handle)),
);

/// Wraps a native buffer address received from the worker isolate.
Uint8List _adoptRemoteChunk(int dataAddress, int handleAddress, int length) {
  final view = Pointer<Uint8>.fromAddress(dataAddress).asTypedList(length);
  _adoptedBufferReaper.attach(view, handleAddress);
  return view;
}

final class _ProxySession implements WebTransport {
  _ProxySession(this._worker, this._id, this.options) {
    // Ask the worker to report when the session disappears.
    unawaited(
      _worker._command(<String, Object?>{'cmd': 'watchClosed', 'session': _id}),
    );
  }

  final WebTransportWorker _worker;
  final int _id;
  final WebTransportOptions options;

  final Completer<void> _closed = Completer<void>();
  late final Future<void> _closedFuture = _closed.future;
  final StreamController<WebTransportBidirectionalStream> _incomingBi =
      StreamController<WebTransportBidirectionalStream>.broadcast();
  final StreamController<WebTransportReceiveStream> _incomingUni =
      StreamController<WebTransportReceiveStream>.broadcast();
  _ProxyDatagrams? _datagrams;
  bool _isClosed = false;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Future<void> get closed => _closedFuture;

  @override
  WebTransportCongestionControl get congestionControl =>
      options.congestionControl;

  @override
  WebTransportReliabilityMode get reliability => _isClosed
      ? WebTransportReliabilityMode.pending
      : WebTransportReliabilityMode.supportsUnreliable;

  @override
  WebTransportDatagramDuplexStream get datagrams =>
      _datagrams ??= _ProxyDatagrams(_worker, _id);

  @override
  Stream<WebTransportBidirectionalStream> get incomingBidirectionalStreams =>
      _incomingBi.stream;

  @override
  Stream<WebTransportReceiveStream> get incomingUnidirectionalStreams =>
      _incomingUni.stream;

  @override
  Future<WebTransportBidirectionalStream> createBidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]) async {
    final response = await _worker._command(<String, Object?>{
      'cmd': 'openBi',
      'session': _id,
      'sendOrder': options?.sendOrder,
    });
    _throwIfError(response, 'createBidirectionalStream');
    return _ProxyBidirectionalStream(
      _ProxyReceiveStream(_worker, response['recv']! as int),
      _ProxySendStream(_worker, response['send']! as int),
    );
  }

  @override
  Future<WebTransportSendStream> createUnidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]) async {
    final response = await _worker._command(<String, Object?>{
      'cmd': 'openUni',
      'session': _id,
      'sendOrder': options?.sendOrder,
    });
    _throwIfError(response, 'createUnidirectionalStream');
    return _ProxySendStream(_worker, response['send']! as int);
  }

  @override
  Future<void> close([WebTransportCloseInfo? closeInfo]) async {
    final info = closeInfo ?? const WebTransportCloseInfo();
    await _worker._command(<String, Object?>{
      'cmd': 'close',
      'session': _id,
      'code': info.closeCode,
      'reason': info.reason,
    });
    _markClosed();
  }

  @override
  Future<WebTransportStats> getStats() async {
    final response = await _worker._command(<String, Object?>{
      'cmd': 'stats',
      'session': _id,
    });
    final micros = response['rtt'] as int? ?? 0;
    return WebTransportStats(
      timestamp: Duration(microseconds: micros),
      minRtt: Duration(microseconds: micros),
      smoothedRtt: Duration(microseconds: micros),
    );
  }

  /// Closes the worker side session.
  Future<void> dispose() async {
    _markClosed();
    await _worker._command(<String, Object?>{
      'cmd': 'disposeSession',
      'session': _id,
    });
  }

  void _onIncomingBi(Map<String, Object?> message) {
    if (_incomingBi.isClosed) return;
    _incomingBi.add(
      _ProxyBidirectionalStream(
        _ProxyReceiveStream(_worker, message['recv']! as int),
        _ProxySendStream(_worker, message['send']! as int),
      ),
    );
  }

  void _onIncomingUni(Map<String, Object?> message) {
    if (_incomingUni.isClosed) return;
    _incomingUni.add(_ProxyReceiveStream(_worker, message['recv']! as int));
  }

  void _markClosed() {
    if (_isClosed) return;
    _isClosed = true;
    if (!_closed.isCompleted) _closed.complete();
    if (!_incomingBi.isClosed) _incomingBi.close();
    if (!_incomingUni.isClosed) _incomingUni.close();
    _datagrams?.dispose();
  }

  void _throwIfError(Map<String, Object?> response, String operation) {
    if (response['error'] case final String error) {
      throw WebTransportError(
        source: WebTransportErrorSource.session,
        message: error,
      );
    }
  }
}

final class _ProxyBidirectionalStream implements WebTransportBidirectionalStream {
  _ProxyBidirectionalStream(this.readable, this.writable);

  @override
  final _ProxyReceiveStream readable;

  @override
  final _ProxySendStream writable;
}

final class _ProxySendStream implements WebTransportSendStream {
  _ProxySendStream(this._worker, this._id);

  final WebTransportWorker _worker;
  final int _id;
  int? _sendOrder;

  @override
  int? get sendOrder => _sendOrder;

  @override
  set sendOrder(int? value) {
    _sendOrder = value;
    unawaited(
      _worker._command(<String, Object?>{
        'cmd': 'sendOrder',
        'stream': _id,
        'value': value,
      }),
    );
  }

  @override
  Future<void> write(List<int> data) async {
    final payload = TransferableTypedData.fromList(<Uint8List>[
      data is Uint8List ? data : Uint8List.fromList(data),
    ]);
    final response = await _worker._command(<String, Object?>{
      'cmd': 'write',
      'stream': _id,
      'data': payload,
    });
    if (response['error'] case final String error) {
      throw WebTransportError(
        source: WebTransportErrorSource.stream,
        message: error,
      );
    }
  }

  @override
  Future<void> close() async {
    final response = await _worker._command(<String, Object?>{
      'cmd': 'closeSend',
      'stream': _id,
    });
    if (response['error'] case final String error) {
      throw WebTransportError(
        source: WebTransportErrorSource.stream,
        message: error,
      );
    }
  }

  @override
  Future<void> abort([int errorCode = 0]) async {
    await _worker._command(<String, Object?>{
      'cmd': 'abortSend',
      'stream': _id,
      'code': errorCode,
    });
  }
}

final class _ProxyReceiveStream implements WebTransportReceiveStream {
  _ProxyReceiveStream(this._worker, this._id);

  final WebTransportWorker _worker;
  final int _id;
  StreamController<Uint8List>? _controller;
  bool _eof = false;
  bool _cancelled = false;
  bool _inFlight = false;

  @override
  Stream<Uint8List> get bytes {
    var controller = _controller;
    if (controller == null) {
      controller = StreamController<Uint8List>(
        onListen: _pull,
        onResume: _pull,
        onCancel: () {
          _cancelled = true;
        },
      );
      _controller = controller;
      _pull();
    }
    return controller.stream;
  }

  @override
  Future<Uint8List?> read() async {
    if (_eof) return null;
    final response = await _worker._command(<String, Object?>{
      'cmd': 'readNext',
      'stream': _id,
    });
    if (response['eof'] == true) {
      _eof = true;
      return null;
    }
    if (response['error'] case final String error) {
      throw WebTransportError(
        source: WebTransportErrorSource.stream,
        message: error,
        streamErrorCode: response['code'] as int?,
      );
    }
    return _adoptRemoteChunk(
      response['data']! as int,
      response['handle']! as int,
      response['len']! as int,
    );
  }

  @override
  Future<void> cancel([int errorCode = 0]) async {
    _cancelled = true;
    await _worker._command(<String, Object?>{
      'cmd': 'cancelRecv',
      'stream': _id,
      'code': errorCode,
    });
    final controller = _controller;
    if (controller != null && !controller.isClosed) await controller.close();
  }

  void _pull() {
    final controller = _controller;
    if (controller == null ||
        _eof ||
        _cancelled ||
        _inFlight ||
        controller.isPaused ||
        controller.isClosed) {
      return;
    }
    _inFlight = true;
    unawaited(() async {
      try {
        final chunk = await read();
        _inFlight = false;
        if (controller.isClosed) return;
        if (chunk == null) {
          await controller.close();
          return;
        }
        controller.add(chunk);
        _pull();
      } on Object catch (error, stackTrace) {
        _inFlight = false;
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
          await controller.close();
        }
      }
    }());
  }
}

final class _ProxyDatagrams implements WebTransportDatagramDuplexStream {
  _ProxyDatagrams(this._worker, this._session);

  final WebTransportWorker _worker;
  final int _session;
  StreamController<Uint8List>? _controller;
  bool _pumping = false;
  bool _cancelled = false;
  int _maxDatagramSize = -1;

  @override
  int get maxDatagramSize => _maxDatagramSize;

  @override
  Stream<Uint8List> get readable {
    var controller = _controller;
    if (controller == null) {
      controller = StreamController<Uint8List>.broadcast(
        onListen: _pump,
        onCancel: () {
          _cancelled = true;
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
    final payload = TransferableTypedData.fromList(<Uint8List>[
      data is Uint8List ? data : Uint8List.fromList(data),
    ]);
    final response = await _worker._command(<String, Object?>{
      'cmd': 'datagramWrite',
      'session': _session,
      'data': payload,
    });
    if (response['error'] case final String error) {
      throw WebTransportError(
        source: WebTransportErrorSource.session,
        message: error,
      );
    }
  }

  void dispose() {
    _cancelled = true;
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
          _cancelled ||
          controller == null ||
          controller.isClosed ||
          controller.isPaused) {
        return;
      }
      unawaited(() async {
        final response = await _worker._command(<String, Object?>{
          'cmd': 'datagramRead',
          'session': _session,
        });
        if (response['maxDatagramSize'] case final int size) {
          _maxDatagramSize = size;
        }
        if (response['error'] case final String error) {
          _pumping = false;
          if (!controller.isClosed) {
            controller.addError(
              WebTransportError(
                source: WebTransportErrorSource.session,
                message: error,
              ),
            );
          }
          return;
        }
        if (response['eof'] == true) {
          _pumping = false;
          return;
        }
        final payload = response['bytes'];
        if (payload is TransferableTypedData) {
          final chunk = payload.materialize().asUint8List();
          if (!controller.isClosed) controller.add(chunk);
        }
        pump();
      }());
    }

    pump();
  }
}

// ---------------------------------------------------------------------------
// Worker isolate
// ---------------------------------------------------------------------------

final class _WorkerBootstrap {
  const _WorkerBootstrap(
    this.main, {
    required this.workerThreads,
    required this.dispatchBatchMax,
    required this.chunkSize,
  });

  final SendPort main;
  final int workerThreads;
  final int dispatchBatchMax;
  final int chunkSize;
}

final class _WorkerState {
  _WorkerState(this.main, this.chunkSize);

  final SendPort main;
  final int chunkSize;
  final Map<int, NativeSession> sessions = <int, NativeSession>{};
  final Map<int, NativeSendStream> senders = <int, NativeSendStream>{};
  final Map<int, NativeReceiveStream> receivers = <int, NativeReceiveStream>{};
  int nextSessionId = 1;
  int nextStreamId = 1;

  void send(Map<String, Object?> message) => main.send(message);
}

void _workerEntry(_WorkerBootstrap bootstrap) {
  final receive = ReceivePort();
  final state = _WorkerState(bootstrap.main, bootstrap.chunkSize);
  bootstrap.main.send(receive.sendPort);

  nativeRuntime.start(
    workerThreads: bootstrap.workerThreads,
    dispatchBatchMax: bootstrap.dispatchBatchMax,
  );

  receive.listen((dynamic raw) {
    if (raw is! Map) return;
    unawaited(_handleCommand(state, raw.cast<String, Object?>()));
  });
}

Future<void> _handleCommand(
  _WorkerState state,
  Map<String, Object?> message,
) async {
  final id = message['id'];
  void respond([Map<String, Object?> extra = const <String, Object?>{}]) {
    if (id is int) state.send(<String, Object?>{'ev': 'response', 'id': id, ...extra});
  }

  void fail(Object error, [int status = 0]) {
    if (id is int) {
      state.send(<String, Object?>{
        'ev': 'response',
        'id': id,
        'error': '$error',
        'status': status,
      });
    }
  }

  switch (message['cmd'] as String?) {
    case 'connect':
      try {
        final options = WebTransportOptions(
          serverCertificateHashes: <WebTransportHash>[
            for (final entry in (message['hashes'] as List<Object?>? ?? const []))
              WebTransportHash(
                algorithm: (entry! as List<Object?>)[0]! as String,
                value: (entry[1]! as Uint8List),
              ),
          ],
        );
        final transport = NativeWebTransport(
          message['url']! as String,
          options,
          message['insecure'] == true,
        );
        await transport.ready;
        final session = transport.session!;
        final sessionId = state.nextSessionId++;
        state.sessions[sessionId] = session;
        _pumpIncoming(state, sessionId, session);
        unawaited(
          session.closed.whenComplete(
            () => state.send(<String, Object?>{
              'ev': 'closed',
              'session': sessionId,
            }),
          ),
        );
        respond(<String, Object?>{'session': sessionId});
      } on Object catch (error) {
        fail(error);
      }

    case 'watchClosed':
      respond();

    case 'openBi':
      try {
        final session = state.sessions[message['session']]!;
        final stream = await session.createBidirectionalStream();
        final send = stream.writable as NativeSendStream;
        final recv = stream.readable as NativeReceiveStream;
        final sendId = state.nextStreamId++;
        final recvId = state.nextStreamId++;
        state.senders[sendId] = send;
        state.receivers[recvId] = recv;
        respond(<String, Object?>{'send': sendId, 'recv': recvId});
      } on Object catch (error) {
        fail(error);
      }

    case 'openUni':
      try {
        final session = state.sessions[message['session']]!;
        final send =
            (await session.createUnidirectionalStream()) as NativeSendStream;
        final sendId = state.nextStreamId++;
        state.senders[sendId] = send;
        respond(<String, Object?>{'send': sendId});
      } on Object catch (error) {
        fail(error);
      }

    case 'sendOrder':
      final send = state.senders[message['stream']];
      if (send != null) send.sendOrder = message['value'] as int?;
      respond();

    case 'write':
      try {
        final send = state.senders[message['stream']]!;
        final payload = (message['data']! as TransferableTypedData).materialize();
        await send.write(payload.asUint8List());
        respond();
      } on Object catch (error) {
        fail(error);
      }

    case 'closeSend':
      try {
        await state.senders[message['stream']]!.close();
        respond();
      } on Object catch (error) {
        fail(error);
      }

    case 'abortSend':
      final send = state.senders.remove(message['stream']);
      if (send != null) {
        await send.abort(message['code'] as int? ?? 0);
        send.dispose();
      }
      respond();

    case 'readNext':
      final streamId = message['stream']! as int;
      final receive = state.receivers[streamId];
      if (receive == null) {
        if (id is int) {
          state.send(<String, Object?>{
            'ev': 'readResult',
            'id': id,
            'eof': true,
          });
        }
        return;
      }
      final buffer = NativeBuffer(state.chunkSize);
      final opId = nativeRuntime.register((event) {
        if (event.isEof) {
          buffer.free();
          if (id is int) {
            state.send(<String, Object?>{
              'ev': 'readResult',
              'id': id,
              'eof': true,
            });
          }
          state.receivers.remove(streamId);
          receive.dispose();
          return;
        }
        if (!event.isOk) {
          buffer.free();
          if (id is int) {
            state.send(<String, Object?>{
              'ev': 'readResult',
              'id': id,
              'error': event.message ?? 'read failed',
              'code': event.aux,
            });
          }
          return;
        }
        // Ownership moves to the requesting isolate; do NOT free the buffer.
        if (id is int) {
          state.send(<String, Object?>{
            'ev': 'readResult',
            'id': id,
            'data': buffer.data.address,
            'handle': buffer.handle.address,
            'len': event.aux,
          });
        }
      });
      final status = b.wt_recv_stream_read(
        receive.handle,
        buffer.data,
        state.chunkSize,
        opId,
      );
      if (status != b.wt_status_t.WT_OK) {
        nativeRuntime.cancel(opId);
        buffer.free();
        if (id is int) {
          state.send(<String, Object?>{
            'ev': 'readResult',
            'id': id,
            'error': 'WT_ERR_OP_BUSY',
          });
        }
      }

    case 'cancelRecv':
      final receive = state.receivers.remove(message['stream']);
      if (receive != null) {
        await receive.cancel(message['code'] as int? ?? 0);
        receive.dispose();
      }
      respond();

    case 'datagramWrite':
      try {
        final session = state.sessions[message['session']]!;
        final payload = (message['data']! as TransferableTypedData).materialize();
        await session.datagrams.write(payload.asUint8List());
        respond();
      } on Object catch (error) {
        fail(error);
      }

    case 'datagramRead':
      final session = state.sessions[message['session']];
      if (session == null) {
        if (id is int) {
          state.send(<String, Object?>{
            'ev': 'datagramResult',
            'id': id,
            'eof': true,
          });
        }
        return;
      }
      final opId = nativeRuntime.register((event) {
        if (id is! int) return;
        if (!event.isOk || event.data == null) {
          state.send(<String, Object?>{
            'ev': 'datagramResult',
            'id': id,
            'error': event.message ?? 'datagram receive failed',
          });
          return;
        }
        // Datagrams arrive as an owned Dart list, so they travel as a
        // transferable payload rather than as shared native memory.
        state.send(<String, Object?>{
          'ev': 'datagramResult',
          'id': id,
          'bytes': TransferableTypedData.fromList(<Uint8List>[event.data!]),
          'maxDatagramSize': session.datagrams.maxDatagramSize,
        });
      });
      final status = b.wt_connection_recv_datagram(session.connection, opId);
      if (status != b.wt_status_t.WT_OK) {
        nativeRuntime.cancel(opId);
        if (id is int) {
          state.send(<String, Object?>{
            'ev': 'datagramResult',
            'id': id,
            'error': 'WT_ERR_OP_BUSY',
          });
        }
      }

    case 'stats':
      final session = state.sessions[message['session']];
      respond(<String, Object?>{'rtt': session?.rtt.inMicroseconds ?? 0});

    case 'close':
      final session = state.sessions[message['session']];
      if (session != null) {
        await session.close(
          WebTransportCloseInfo(
            closeCode: message['code'] as int? ?? 0,
            reason: message['reason'] as String? ?? '',
          ),
        );
      }
      respond();

    case 'disposeSession':
      final session = state.sessions.remove(message['session']);
      session?.dispose();
      respond();

    case 'shutdown':
      for (final session in state.sessions.values) {
        session.dispose();
      }
      state.sessions.clear();
      state.senders.clear();
      state.receivers.clear();
      respond();
  }
}

/// Pushes peer initiated streams to the requesting isolate.
void _pumpIncoming(_WorkerState state, int sessionId, NativeSession session) {
  unawaited(() async {
    await for (final stream in session.incomingBidirectionalStreams) {
      final sendId = state.nextStreamId++;
      final recvId = state.nextStreamId++;
      state.senders[sendId] = stream.writable as NativeSendStream;
      state.receivers[recvId] = stream.readable as NativeReceiveStream;
      state.send(<String, Object?>{
        'ev': 'bi',
        'session': sessionId,
        'send': sendId,
        'recv': recvId,
      });
    }
  }());

  unawaited(() async {
    await for (final stream in session.incomingUnidirectionalStreams) {
      final recvId = state.nextStreamId++;
      state.receivers[recvId] = stream as NativeReceiveStream;
      state.send(<String, Object?>{
        'ev': 'uni',
        'session': sessionId,
        'recv': recvId,
      });
    }
  }());
}
