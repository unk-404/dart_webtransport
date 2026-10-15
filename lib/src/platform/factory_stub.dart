/// Factory used when neither `dart:io` nor `dart:js_interop` is available.
///
/// This file exists only so the conditional export in
/// `package:flutter_webtransport/flutter_webtransport.dart` always resolves;
/// every real platform picks one of the other two implementations.
library;

import '../api.dart';

/// Unsupported on this platform.
WebTransport createWebTransport(String url, [WebTransportOptions? options]) =>
    throw UnsupportedError(
      'flutter_webtransport has no WebTransport implementation for this '
      'platform',
    );
