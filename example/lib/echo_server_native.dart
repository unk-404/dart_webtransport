import 'package:webtransport/webtransport.dart' show WebTransportReceiveStreamX;
import 'package:webtransport/webtransport_ffi.dart'
    show
        WebTransportSelfSignedIdentity,
        WebTransportServer,
        WebTransportServerConfig;

import 'echo_server_types.dart';

/// Native implementation: starts a self-signed echo server on an ephemeral port.
Future<LocalEchoServer?> startLocalEchoServer() async {
  final config = WebTransportServerConfig()
    ..identity = const WebTransportSelfSignedIdentity(<String>[
      'localhost',
      '127.0.0.1',
    ])
    ..bindAddress = '127.0.0.1';
  final server = await WebTransportServer.bind(config);

  server.requests.listen((request) async {
    final session = await request.accept();
    // Echo datagrams back.
    session.datagrams.readable.listen(session.datagrams.write);
    // Echo bidirectional streams back.
    session.incomingBidirectionalStreams.listen((stream) async {
      final payload = await stream.readable.toBytes();
      await stream.writable.write(payload);
      await stream.writable.close();
    });
    // Drain unidirectional streams.
    session.incomingUnidirectionalStreams.listen((stream) async {
      await stream.toBytes();
    });
  });

  return LocalEchoServer(
    url: 'https://127.0.0.1:${server.port}/echo',
    certificateHashes: server.certificateHashes,
    dispose: server.dispose,
  );
}
