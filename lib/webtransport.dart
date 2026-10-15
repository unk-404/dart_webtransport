/// WebTransport for Flutter — one portable client API for web and native.
///
/// ```dart
/// import 'package:webtransport/webtransport.dart';
///
/// final transport = createWebTransport(
///   'https://example.com:4433/echo',
///   WebTransportOptions(
///     serverCertificateHashes: [WebTransportHash(value: digest)],
///   ),
/// );
/// await transport.ready;
///
/// // Unreliable, unordered messages.
/// transport.datagrams.write(utf8.encode('ping'));
/// transport.datagrams.readable.listen(print);
///
/// // Reliable, ordered streams.
/// final stream = await transport.createBidirectionalStream();
/// stream.writable.write(utf8.encode('hello'));
/// await stream.writable.close();
/// await for (final chunk in stream.readable.bytes) {
///   print(chunk);
/// }
///
/// await transport.close(WebTransportCloseInfo(closeCode: 0));
/// ```
///
/// The type names, method names and semantics mirror the browser
/// [WebTransport API](https://w3c.github.io/webtransport/), so the same code
/// runs unchanged in all three configurations:
///
/// | configuration | implementation |
/// | --- | --- |
/// | Flutter desktop / mobile | `rust/` (the `wtransport` code asset) inside a worker isolate |
/// | Flutter web (JS/Wasm) | the browser's native `WebTransport` |
/// | Dart VM tests | `rust/` inside a worker isolate |
///
/// Nothing extra has to be imported or configured: `createWebTransport` picks
/// the implementation at compile time through a conditional import, and no
/// `dart:ffi` code is reachable from a web build.
///
/// Native only functionality — the server side, the raw `ffi` bindings, the
/// in-process backend and the worker controls — lives in
/// `package:webtransport/webtransport_ffi.dart`.
///
/// ## Differences from the browser
///
/// Dart has neither `WritableStream` nor `ReadableStream`, so:
///
///  * a send stream is an object with `write`/`close`/`abort` returning
///    `Future`s instead of a `getWriter()` handshake;
///  * a receive stream is consumed through
///    [WebTransportReceiveStream.bytes] (a `Stream`) or
///    [WebTransportReceiveStream.read], instead of a reader lock;
///  * `WebTransport.datagrams.readable` is a Dart `Stream`.
library;

export 'src/api.dart';
export 'src/platform/factory_stub.dart'
    if (dart.library.io) 'src/platform/factory_native.dart'
    if (dart.library.js_interop) 'src/platform/factory_web.dart';
