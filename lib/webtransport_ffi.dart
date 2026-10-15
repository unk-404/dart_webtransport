/// Native only entry points.
///
/// Import this instead of `package:webtransport/webtransport.dart`
/// when you need functionality that a browser cannot provide:
///
///  * [WebTransportServer] — listening for WebTransport sessions (the
///    `wtransport` server side, including self-signed identities and the
///    certificate digest a client should pin);
///  * [NativeWebTransport] and [NativeSession] — the in-process backend, which
///    avoids the worker isolate (and therefore the message hop) when the calling
///    isolate is already dedicated;
///  * [WebTransportWorker] — the worker isolate itself, for explicit lifecycle
///    control;
///  * the raw `ffigen` bindings (`wt_*` functions and `wt_*_t` structs);
///  * [NativeBuffer] — native memory Dart can write into and hand over without
///    copying;
///  * [WebTransportRuntime] — runtime lifecycle and diagnostics.
///
/// This library is not available on the web: it reaches into `dart:ffi`.
library;

export 'webtransport_bindings_generated.dart';
export 'src/api.dart';
export 'src/native/isolate_backend.dart' show WebTransportWorker;
export 'src/native/memory.dart'
    show NativeBuffer, NativeEvent, WebTransportException;
export 'src/native/runtime.dart' show WebTransportRuntime, nativeRuntime;
export 'src/native/server.dart'
    show
        WebTransportDerIdentity,
        WebTransportPemFileIdentity,
        WebTransportPemIdentity,
        WebTransportSelfSignedIdentity,
        WebTransportServer,
        WebTransportServerConfig,
        WebTransportServerIdentity,
        WebTransportSessionRequest;
export 'src/native/session.dart'
    show NativeReceiveStream, NativeSendStream, NativeSession;
export 'src/native/transport.dart' show NativeWebTransport;

import 'package:ffi/ffi.dart';

import 'webtransport_bindings_generated.dart';

/// Version string reported by the library that was actually loaded.
String get nativeVersion => wt_version_string().cast<Utf8>().toDartString();

/// ABI version of the loaded library, packed as `(major << 16) | minor`.
int get nativeAbiVersion => wt_abi_version();
