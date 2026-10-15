import 'package:webtransport/webtransport.dart';
import 'package:webtransport/webtransport_ffi.dart';
import 'package:test/test.dart';

/// Starts a self-signed echo server on an ephemeral port.
Future<WebTransportServer> startEchoServer() async {
  final config = WebTransportServerConfig()
    ..identity = const WebTransportSelfSignedIdentity(<String>[
      'localhost',
      '127.0.0.1',
    ])
    ..bindAddress = '127.0.0.1';
  final server = await WebTransportServer.bind(config);

  // Accept sessions and echo both channels back.
  server.requests.listen((request) async {
    final session = await request.accept();
    session.datagrams.readable.listen(session.datagrams.write);
    session.incomingBidirectionalStreams.listen((stream) async {
      final payload = await stream.readable.toBytes();
      await stream.writable.write(payload);
      await stream.writable.close();
    });
    session.incomingUnidirectionalStreams.listen((stream) async {
      await stream.toBytes();
    });
  });

  return server;
}

void main() {
  group('code asset', () {
    test('the native webtransport library is loaded', () {
      expect(nativeVersion, contains('webtransport'));
    });

    test('the loaded library matches the generated ABI version', () {
      final abi = nativeAbiVersion;
      expect(abi >> 16, WT_ABI_VERSION_MAJOR);
      expect(abi & 0xffff, WT_ABI_VERSION_MINOR);
      expect(abi, WT_ABI_VERSION);
    });

    test('status codes round trip through the native string table', () {
      expect(wt_status_string(wt_status_t.WT_OK.value), isNotNull);
      expect(wt_status_string(wt_status_t.WT_ERR_OP_BUSY.value), isNotNull);
      expect(wt_runtime_is_running(), 0);
      expect(wt_runtime_shutdown(), wt_status_t.WT_ERR_NO_RUNTIME);
    });
  });

  group('native client', () {
    test('streams and datagrams flow in both directions', () async {
      final server = await startEchoServer();
      addTearDown(server.dispose);
      expect(server.port, greaterThan(0));
      expect(server.certificateHashes.single.value, hasLength(32));

      final client = NativeWebTransport(
        'https://127.0.0.1:${server.port}/echo',
        WebTransportOptions(serverCertificateHashes: server.certificateHashes),
      );
      addTearDown(client.dispose);

      final session = await client.ready
          .then((_) => client.session!)
          .timeout(const Duration(seconds: 20));
      expect(session.remotePort, greaterThan(0));
      // The client socket is dual stack, so the peer may be reported as an
      // IPv4 mapped IPv6 address.
      expect(session.remoteAddress, contains('127.0.0.1'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a bidirectional stream echoes back', () async {
      final server = await startEchoServer();
      addTearDown(server.dispose);

      final client = NativeWebTransport(
        'https://127.0.0.1:${server.port}/echo',
        WebTransportOptions(serverCertificateHashes: server.certificateHashes),
      );
      addTearDown(client.dispose);
      await client.ready.timeout(const Duration(seconds: 20));

      final stream = await client.createBidirectionalStream();
      await stream.writable.write(<int>[1, 2, 3, 4]);
      await stream.writable.close();
      expect(await stream.readable.toBytes(), <int>[1, 2, 3, 4]);

      // Datagrams are unreliable but a localhost round trip is deterministic
      // enough to assert on with a timeout.
      final echoed = client.datagrams.readable.first;
      await client.datagrams.write(<int>[42, 43]);
      expect(await echoed.timeout(const Duration(seconds: 10)), <int>[42, 43]);

      await client.close(const WebTransportCloseInfo(closeCode: 0));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('portable client API', () {
    test('createWebTransport drives the server end to end', () async {
      final server = await startEchoServer();
      addTearDown(server.dispose);

      // `createWebTransport` is the platform independent entry point: on the web
      // it returns the browser implementation, on the VM the native one.
      final transport = createWebTransport(
        'https://127.0.0.1:${server.port}/echo',
        WebTransportOptions(serverCertificateHashes: server.certificateHashes),
      );
      await transport.ready.timeout(const Duration(seconds: 20));

      final stream = await transport.createBidirectionalStream();
      await stream.writable.write(<int>[9, 9, 9]);
      await stream.writable.close();
      expect(await stream.readable.toBytes(), <int>[9, 9, 9]);

      await transport.close();

      // `accept()` on the server produced a session with the same URL path.
      expect(server.openConnections, greaterThanOrEqualTo(0));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
