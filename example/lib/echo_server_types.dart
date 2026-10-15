import 'package:webtransport/webtransport.dart';

/// A WebTransport echo server running in this process.
///
/// Only the native backend can listen for sessions, so this type is produced by
/// the native implementation of [startLocalEchoServer] and never on the web.
final class LocalEchoServer {
  LocalEchoServer({
    required this.url,
    required this.certificateHashes,
    required this.dispose,
  });

  /// URL the client should connect to.
  final String url;

  /// Digests to pin, as a browser would with `serverCertificateHashes`.
  final List<WebTransportHash> certificateHashes;

  /// Stops the server.
  final void Function() dispose;
}
