/// Web backend: an adapter over the browser's own `WebTransport`.
///
/// The browser already implements the protocol natively and off the main
/// thread, so this adapter only translates between the Dart surface of
/// [api.dart] and the JavaScript one. Nothing here copies a payload: chunks are
/// handed over as `Uint8Array` views of the same memory the browser filled.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../api.dart';

/// Minimal typed access to the browser constructor.
///
/// Declared here rather than through `package:web` so the options object can be
/// built with `jsify`, which avoids the `BufferSource` union types entirely.
@JS('WebTransport')
extension type _JsWebTransport._(JSObject _) implements JSObject {
  external factory _JsWebTransport(String url, JSAny options);

  external web.WebTransportDatagramDuplexStream get datagrams;

  external web.ReadableStream get incomingBidirectionalStreams;

  external web.ReadableStream get incomingUnidirectionalStreams;

  external JSPromise<JSAny?> get ready;

  external JSPromise<JSAny?> get closed;

  external JSPromise<web.WebTransportBidirectionalStream>
  createBidirectionalStream([JSObject? options]);

  external JSPromise<JSObject> createUnidirectionalStream([JSObject? options]);

  external void close(JSObject closeInfo);

  external String get reliability;
}

/// Creates a browser backed WebTransport session.
WebTransport createWebWebTransport(String url, [WebTransportOptions? options]) =>
    _BrowserWebTransport(url, options ?? const WebTransportOptions());

final class _BrowserWebTransport implements WebTransport {
  _BrowserWebTransport(String url, WebTransportOptions options) {
    if (options.serverCertificateHashes.isNotEmpty) {
      final hashes = <Object?>[
        for (final hash in options.serverCertificateHashes)
          <String, Object?>{
            'algorithm': hash.algorithm,
            'value': Uint8List.fromList(hash.value).toJS,
          },
      ];
      _options = <String, Object?>{
        'allowPooling': options.allowPooling,
        'requireUnreliable': options.requireUnreliable,
        'congestionControl': options.congestionControl.wireName,
        'serverCertificateHashes': hashes,
      };
    } else {
      _options = <String, Object?>{
        'allowPooling': options.allowPooling,
        'requireUnreliable': options.requireUnreliable,
        'congestionControl': options.congestionControl.wireName,
      };
    }
    _congestionControl = options.congestionControl;
    _transport = _JsWebTransport(url, _options.jsify()!);
    _datagrams = _BrowserDatagrams(_transport);
  }

  late final _JsWebTransport _transport;
  late final Map<String, Object?> _options;
  late final WebTransportCongestionControl _congestionControl;
  late final _BrowserDatagrams _datagrams;

  @override
  Future<void> get ready => _transport.ready.toDart.then((_) {});

  @override
  Future<void> get closed =>
      _transport.closed.toDart.then((_) {}).catchError((Object _) {});

  @override
  WebTransportDatagramDuplexStream get datagrams => _datagrams;

  @override
  WebTransportCongestionControl get congestionControl => _congestionControl;

  @override
  WebTransportReliabilityMode get reliability =>
      switch (_transport.reliability) {
        'reliable-only' => WebTransportReliabilityMode.reliableOnly,
        'supports-unreliable' => WebTransportReliabilityMode.supportsUnreliable,
        _ => WebTransportReliabilityMode.pending,
      };

  @override
  Stream<WebTransportBidirectionalStream> get incomingBidirectionalStreams =>
      _readStream(_transport.incomingBidirectionalStreams)
          .where((value) => value != null)
          .map(
            (value) => _BrowserBidirectionalStream(
              value! as web.WebTransportBidirectionalStream,
            ),
          );

  @override
  Stream<WebTransportReceiveStream> get incomingUnidirectionalStreams =>
      _readStream(_transport.incomingUnidirectionalStreams)
          .where((value) => value != null)
          .map(
            (value) => _BrowserReceiveStream(value! as web.ReadableStream),
          );

  @override
  Future<WebTransportBidirectionalStream> createBidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]) async {
    final result = await _transport
        .createBidirectionalStream(_sendStreamOptions(options))
        .toDart;
    return _BrowserBidirectionalStream(result);
  }

  @override
  Future<WebTransportSendStream> createUnidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]) async {
    final stream = await _transport
        .createUnidirectionalStream(_sendStreamOptions(options))
        .toDart;
    return _BrowserSendStream(stream as web.WritableStream);
  }

  @override
  Future<void> close([WebTransportCloseInfo? closeInfo]) async {
    final info = closeInfo ?? const WebTransportCloseInfo();
    _transport.close(
      <String, Object?>{
        'closeCode': info.closeCode,
        'reason': info.reason,
      }.jsify()! as JSObject,
    );
  }

  @override
  Future<WebTransportStats> getStats() async => const WebTransportStats();

  JSObject? _sendStreamOptions(WebTransportSendStreamOptions? options) {
    final order = options?.sendOrder;
    if (order == null) return null;
    return <String, Object?>{'sendOrder': order}.jsify()! as JSObject;
  }
}

/// Runs [body] with the (possibly null) JavaScript options object.
final class _BrowserBidirectionalStream
    implements WebTransportBidirectionalStream {
  _BrowserBidirectionalStream(web.WebTransportBidirectionalStream stream)
    : readable = _BrowserReceiveStream(stream.readable as web.ReadableStream),
      writable = _BrowserSendStream(stream.writable as web.WritableStream);

  @override
  final WebTransportReceiveStream readable;

  @override
  final WebTransportSendStream writable;
}

final class _BrowserSendStream implements WebTransportSendStream {
  _BrowserSendStream(web.WritableStream stream) : _writer = stream.getWriter();

  final web.WritableStreamDefaultWriter _writer;
  int? _sendOrder;

  @override
  int? get sendOrder => _sendOrder;

  @override
  set sendOrder(int? value) => _sendOrder = value;

  @override
  Future<void> write(List<int> data) async {
    final view = data is Uint8List ? data : Uint8List.fromList(data);
    await _writer.write(view.toJS).toDart;
  }

  @override
  Future<void> close() async {
    await _writer.close().toDart;
    _writer.releaseLock();
  }

  @override
  Future<void> abort([int errorCode = 0]) async {
    await _writer.abort(errorCode.toJS).toDart;
    _writer.releaseLock();
  }
}

final class _BrowserReceiveStream implements WebTransportReceiveStream {
  _BrowserReceiveStream(web.ReadableStream stream) : _stream = stream;

  final web.ReadableStream _stream;

  @override
  Stream<Uint8List> get bytes => _readStream(_stream).map(_asBytes);

  @override
  Future<Uint8List?> read() async {
    final reader = _stream.getReader() as web.ReadableStreamDefaultReader;
    try {
      final result = await reader.read().toDart;
      if (result.done) return null;
      final value = result.value;
      return value == null ? Uint8List(0) : _asBytes(value);
    } finally {
      reader.releaseLock();
    }
  }

  @override
  Future<void> cancel([int errorCode = 0]) async {
    final reader = _stream.getReader() as web.ReadableStreamDefaultReader;
    try {
      await reader.cancel(errorCode.toJS).toDart;
    } finally {
      reader.releaseLock();
    }
  }
}

final class _BrowserDatagrams implements WebTransportDatagramDuplexStream {
  _BrowserDatagrams(this._transport);

  final _JsWebTransport _transport;
  web.WritableStreamDefaultWriter? _writer;

  @override
  int get maxDatagramSize => _transport.datagrams.maxDatagramSize;

  @override
  Stream<Uint8List> get readable =>
      _readStream(_transport.datagrams.readable).map(_asBytes);

  @override
  Future<void> write(List<int> data) async {
    final writer =
        _writer ??= _transport.datagrams.writable.getWriter();
    final view = data is Uint8List ? data : Uint8List.fromList(data);
    await writer.write(view.toJS).toDart;
  }
}

/// Reads a JavaScript `ReadableStream` as a Dart stream of raw values.
Stream<Object?> _readStream(web.ReadableStream stream) {
  late StreamController<Object?> controller;
  web.ReadableStreamDefaultReader? reader;

  Future<void> pump() async {
    try {
      while (true) {
        final result = await reader!.read().toDart;
        if (result.done) {
          await controller.close();
          return;
        }
        final value = result.value;
        if (value != null) controller.add(value);
      }
    } on Object catch (error, stackTrace) {
      if (!controller.isClosed) {
        controller.addError(error, stackTrace);
        await controller.close();
      }
    }
  }

  controller = StreamController<Object?>(
    onListen: () {
      reader = stream.getReader() as web.ReadableStreamDefaultReader;
      unawaited(pump());
    },
    onPause: () {},
    onResume: () {},
    onCancel: () async {
      await reader?.cancel().toDart;
      reader?.releaseLock();
    },
  );
  return controller.stream;
}

/// Copies a JavaScript `Uint8Array` chunk into a Dart list.
///
/// `isA` performs the platform correct runtime check; the `as` that follows is
/// then a pure static-cast convenience, which is what the analysis hint on
/// runtime checks between `Object` and JS interop types is about.
Uint8List _asBytes(Object? value) {
  if (value == null) return Uint8List(0);
  if (value.isA<JSUint8Array>()) {
    // ignore: invalid_runtime_check_with_js_interop_types
    return (value as JSUint8Array).toDart;
  }
  if (value.isA<JSArrayBuffer>()) {
    // ignore: invalid_runtime_check_with_js_interop_types
    return (value as JSArrayBuffer).toDart.asUint8List();
  }
  return Uint8List(0);
}
