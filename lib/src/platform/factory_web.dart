/// Web factory: the automatic client implementation for JavaScript/Wasm.
library;

import '../api.dart';
import '../web/transport.dart';

/// Creates a session on top of the browser's own `WebTransport`.
WebTransport createWebTransport(String url, [WebTransportOptions? options]) =>
    createWebWebTransport(url, options);
