import 'echo_server_types.dart';

/// Web implementation: a browser cannot listen for WebTransport sessions, so
/// the demo has no local server and simply reports that.
Future<LocalEchoServer?> startLocalEchoServer() async => null;
