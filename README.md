# flutter_webtransport

WebTransport (HTTP/3 over QUIC) for Flutter, with one portable client API that
runs **either** on the browser's native `WebTransport` **or** on a Rust
implementation of the protocol (`wtransport`) compiled into the app.

```dart
import 'package:flutter_webtransport/flutter_webtransport.dart';

final transport = createWebTransport(
  'https://example.com:4433/echo',
  WebTransportOptions(
    serverCertificateHashes: [WebTransportHash(value: digest)],
  ),
);
await transport.ready;

transport.datagrams.write(utf8.encode('ping'));       // unreliable, unordered
transport.datagrams.readable.listen(print);

final stream = await transport.createBidirectionalStream();
await stream.writable.write(utf8.encode('hello'));    // reliable, ordered
await stream.writable.close();
await for (final chunk in stream.readable.bytes) {
  print(chunk);
}

await transport.close(const WebTransportCloseInfo(closeCode: 0));
```

The type and method names mirror the
[W3C WebTransport API](https://w3c.github.io/webtransport/), so the same code
runs unchanged everywhere. Nothing extra has to be imported or configured:
`createWebTransport` selects the implementation at compile time.

| configuration | backend |
| --- | --- |
| Flutter desktop / mobile | the Rust code asset, driven from a worker isolate |
| Flutter web (JS / Wasm) | the browser's own `WebTransport` |
| Dart VM (tests, servers) | the Rust code asset |

## Architecture

The binding is layered, and every layer has a single responsibility:

| layer | file(s) | responsibility |
| --- | --- | --- |
| **L0** raw ABI | `src/flutter_webtransport.h` (generated), `lib/flutter_webtransport_bindings_generated.dart` (generated) | the `wt_*` C functions and `wt_*_t` opaque handles |
| **L1** memory safety | `lib/src/native/memory.dart` | status → exception, string / header marshalling, `wt_buffer_t` ownership, copying an event out of its batch before it is freed. No other layer does pointer arithmetic or `malloc`. |
| **L2** async plumbing | `lib/src/native/runtime.dart` | starts the tokio runtime, registers the single `NativeCallable.listener`, correlates completions with their callers, drains each event batch exactly once |
| **L3** objects | `lib/src/native/{transport,session,server}.dart`, `lib/src/web/transport.dart`, `lib/src/native/isolate_backend.dart` | clients, sessions, streams, datagrams — one implementation per backend |
| **L4** contract | `lib/src/api.dart` | the platform neutral WebTransport surface every backend implements |
| **L5** facade | `lib/flutter_webtransport.dart` | the portable API, wired to a backend by a conditional export |

Native-only functionality lives in a **separate** library,
`lib/flutter_webtransport_ffi.dart`: the server side, the in-process backend,
the worker isolate, `NativeBuffer` and the raw `wt_*` bindings. It reaches into
`dart:ffi`, so it is not part of the web build.

### Why it never blocks the UI isolate

The Rust side owns a multi-threaded tokio runtime: no exported function waits on
the network, every asynchronous operation reports its outcome through one
callback, and completions are **coalesced into batches** so a burst of traffic
costs one isolate message instead of one per event.

On top of that, the portable API runs the whole native stack inside a **worker
isolate**:

* the calling isolate never performs a native call, an allocation or a decode —
  it only exchanges messages;
* reads are **pull based**, so a slow consumer stops asking and QUIC flow
  control slows the peer down;
* stream chunks cross the isolate boundary **without a copy**: Dart isolates
  share the address space, so the worker sends the address of the native buffer
  it read into and the receiving isolate wraps that memory in a `Uint8List` that
  frees the handle when it is collected. QUIC → application, zero copies.

If the calling isolate already owns the runtime (for example because it started
a `WebTransportServer`), `createWebTransport` transparently creates the session
in-process instead: the native library exposes a single event sink, so it cannot
be shared with a worker isolate. The interface is identical either way.

## Layout

| path | contents |
| --- | --- |
| `rust/` | the Rust crate implementing the C ABI (`staticlib` + `cdylib` + `rlib`) |
| `rust/cbindgen.toml` | cbindgen configuration — the header is generated from Rust |
| `rust/rust-toolchain.toml` | pinned toolchain and target list |
| `src/flutter_webtransport.h` | **generated** C header — the ABI contract |
| `hook/build.dart` | the Flutter build hook |
| `lib/` | the Dart layers described above |
| `tool/generate_bindings.dart` | regenerates the header *and* the Dart bindings |
| `example/` | Flutter app that runs a server and a client, on native and on web |

## Requirements

* Flutter / Dart SDK with native assets support (developed against Dart 3.13).
* [rustup](https://rustup.rs). `rust/rust-toolchain.toml` pins `1.99.0` and the
  supported targets; `rustup` fetches whatever is missing on first use.
* `clang` / `libclang` — only to *regenerate* the Dart bindings.

## Building

```bash
cd example
flutter build windows      # or: flutter run -d windows
flutter build web          # the browser backend, no Rust involved
```

On native the hook compiles `rust/` in release mode (fat LTO,
`codegen-units = 1`) and Flutter bundles the result, so the product contains:

```
example/build/windows/x64/runner/Release/
├── flutter_webtransport_example.exe
├── flutter_windows.dll
└── webtransport.dll          <-- the code asset built by hook/build.dart
```

## Regenerating the bindings

The Rust sources are the single source of truth; the C header is *generated*
from them. Never edit `src/flutter_webtransport.h` or
`lib/flutter_webtransport_bindings_generated.dart` by hand.

```bash
dart run tool/generate_bindings.dart
```

## Server side (native only)

```dart
import 'package:flutter_webtransport/flutter_webtransport_ffi.dart';

final config = WebTransportServerConfig()
  ..identity = const WebTransportSelfSignedIdentity(['localhost', '127.0.0.1'])
  ..bindAddress = '127.0.0.1';
final server = await WebTransportServer.bind(config);
print(server.port);

await for (final request in server.requests) {
  final session = await request.accept();          // or request.reject(404)
  session.incomingBidirectionalStreams.listen((stream) async {
    await stream.writable.write(await stream.readable.toBytes());
    await stream.writable.close();
  });
}
```

`server.certificateHashes` is the digest a client passes as
`WebTransportOptions.serverCertificateHashes` — the portable way to trust a
self-signed server, exactly as a browser does.

## Notes

* **`CARGO_HOME` / `RUSTUP_HOME`.** Flutter build hooks run with a *filtered*
  environment: `hooks_runner` forwards only a white-list of variables, which does
  not include the Rust toolchain homes. Left alone, `rustup` falls back to
  `%USERPROFILE%\.rustup` and downloads a second copy of the pinned toolchain
  into a location the developer never chose. `hook/build.dart` therefore resolves
  both variables — from the inherited environment, from `hooks: user_defines:` or
  from the Windows user profile — and re-executes itself once with them set. An
  explicit override always wins:

  ```yaml
  hooks:
    user_defines:
      flutter_webtransport:
        cargo_home: D:\Devel\Rust\Cargo
        rustup_home: D:\Devel\Rust\Rustup
  ```

* **`TMP` / `TEMP`.** While the Rust build runs, the hook points `TMP`/`TEMP` at
  a directory inside its own output directory: the MSVC archiver used by `ring`
  creates a scratch file in `%TEMP%`, and on hosts where the inherited temp
  directory is not writable that surfaces as
  `LNK1104: cannot open file '...\lnk{...}.tmp'`.

* **Crypto backend.** The crate uses `wtransport`'s `ring` backend, which needs
  neither CMake nor NASM, so the hook stays self-contained on every host.

* **Platform differences.** Dart has neither `WritableStream` nor
  `ReadableStream`: a send stream is an object with `write`/`close`/`abort`
  returning `Future`s, a receive stream is consumed through its `bytes`
  `Stream` or `read()`, and `datagrams.readable` is a `Stream`. `maxDatagramSize`
  on the native backend reports the QUIC limit, and the native `WebTransportStats`
  only fills in the round-trip time — the rest stays zero rather than being
  guessed.
