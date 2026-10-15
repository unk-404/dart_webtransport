/// Native factory: the automatic client implementation for the Dart VM.
///
/// The native library is driven from a dedicated worker isolate, so the isolate
/// that calls [createWebTransport] never performs a native call. See
/// `src/native/isolate_backend.dart` for the protocol and the zero-copy chunk
/// hand-off.
library;

import 'dart:async';
import 'dart:typed_data';

import '../api.dart';
import '../native/isolate_backend.dart';
import '../native/runtime.dart';
import '../native/transport.dart';

WebTransportWorker? _worker;
Future<WebTransportWorker>? _starting;
int _workerThreads = 0;
int _dispatchBatchMax = 64;
int _chunkSize = 64 * 1024;

/// Tunes the worker isolate that [createWebTransport] will spawn.
///
/// Must be called before the first session is created; later calls are ignored
/// (a warning is not raised, the values simply have no effect).
void configureWebTransportWorker({
  int workerThreads = 0,
  int dispatchBatchMax = 64,
  int chunkSize = 64 * 1024,
}) {
  if (_worker != null || _starting != null) return;
  _workerThreads = workerThreads;
  _dispatchBatchMax = dispatchBatchMax;
  _chunkSize = chunkSize;
}

/// Stops the worker isolate and closes every session it owns.
Future<void> disposeWebTransportWorker() async {
  final worker = _worker ?? await _starting;
  _worker = null;
  _starting = null;
  await worker?.dispose();
}

Future<WebTransportWorker> _ensureWorker() {
  final existing = _worker;
  if (existing != null) return Future<WebTransportWorker>.value(existing);
  return _starting ??=
      WebTransportWorker.spawn(
        workerThreads: _workerThreads,
        dispatchBatchMax: _dispatchBatchMax,
        chunkSize: _chunkSize,
      ).then((worker) {
        _worker = worker;
        return worker;
      });
}

/// Creates a client session.
///
/// Returns immediately with a proxy, exactly like the browser constructor; the
/// worker isolate starts lazily and failures surface through
/// [WebTransport.ready].
///
/// If the calling isolate already owns the native runtime — for example because
/// it started a [WebTransportServer] — the session is created in-process
/// instead: the native library has a single event sink, so it cannot be shared
/// with a worker isolate. The interface is identical either way.
WebTransport createWebTransport(String url, [WebTransportOptions? options]) {
  if (nativeRuntime.isRunning) {
    return NativeWebTransport(url, options);
  }
  return _LazyTransport(
    _ensureWorker().then((worker) => worker.connect(url, options)),
  );
}

/// A transport whose backend starts lazily in the worker isolate.
final class _LazyTransport implements WebTransport {
  _LazyTransport(this._delegate);

  final Future<WebTransport> _delegate;

  @override
  Future<void> get ready => _delegate.then((transport) => transport.ready);

  @override
  Future<void> get closed => _delegate.then((transport) => transport.closed);

  @override
  WebTransportDatagramDuplexStream get datagrams => _LazyDatagrams(_delegate);

  @override
  WebTransportCongestionControl get congestionControl =>
      WebTransportCongestionControl.defaultPolicy;

  @override
  WebTransportReliabilityMode get reliability =>
      WebTransportReliabilityMode.pending;

  @override
  Stream<WebTransportBidirectionalStream> get incomingBidirectionalStreams =>
      _forward((transport) => transport.incomingBidirectionalStreams);

  @override
  Stream<WebTransportReceiveStream> get incomingUnidirectionalStreams =>
      _forward((transport) => transport.incomingUnidirectionalStreams);

  @override
  Future<WebTransportBidirectionalStream> createBidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]) async {
    final transport = await _delegate;
    return transport.createBidirectionalStream(options);
  }

  @override
  Future<WebTransportSendStream> createUnidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]) async {
    final transport = await _delegate;
    return transport.createUnidirectionalStream(options);
  }

  @override
  Future<void> close([WebTransportCloseInfo? closeInfo]) async {
    final transport = await _delegate;
    return transport.close(closeInfo);
  }

  @override
  Future<WebTransportStats> getStats() async {
    final transport = await _delegate;
    return transport.getStats();
  }

  Stream<T> _forward<T>(Stream<T> Function(WebTransport) open) async* {
    final transport = await _delegate;
    yield* open(transport);
  }
}

final class _LazyDatagrams implements WebTransportDatagramDuplexStream {
  _LazyDatagrams(this._delegate);

  final Future<WebTransport> _delegate;

  @override
  int get maxDatagramSize => -1;

  @override
  Stream<Uint8List> get readable async* {
    final transport = await _delegate;
    yield* transport.datagrams.readable;
  }

  @override
  Future<void> write(List<int> data) async {
    final transport = await _delegate;
    await transport.datagrams.write(data);
  }
}
