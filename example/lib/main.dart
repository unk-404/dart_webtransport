import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webtransport/webtransport.dart';

import 'echo_server_stub.dart' if (dart.library.io) 'echo_server_native.dart';
import 'echo_server_types.dart';

/// Demonstrates the portable client API.
///
/// On the native platforms a self-signed echo server is started in this process
/// (with the native-only library) and the client connects to it, pinning its
/// certificate exactly the way a browser does. On the web there is no local
/// server — browsers cannot listen — so the app reports that and the code below
/// is the same either way.
void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final List<String> _log = <String>[];
  LocalEchoServer? _server;
  WebTransport? _client;
  String _status = 'starting…';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    unawaited(_client?.close());
    _server?.dispose();
    super.dispose();
  }

  void _note(String message) {
    if (!mounted) return;
    setState(() {
      _log.add(message);
      if (_log.length > 14) _log.removeAt(0);
    });
  }

  Future<void> _run() async {
    try {
      final server = await startLocalEchoServer();
      if (server == null) {
        _note(
          'no local echo server on this platform (the browser cannot '
          'listen for WebTransport sessions)',
        );
        if (mounted) setState(() => _status = 'idle');
        return;
      }
      _server = server;
      _note('server listening on ${server.url}');

      // The portable entry point: on the web this returns the browser
      // implementation, on the VM the native one.
      final client = createWebTransport(
        server.url,
        WebTransportOptions(serverCertificateHashes: server.certificateHashes),
      );
      _client = client;
      await client.ready.timeout(const Duration(seconds: 20));
      _note(
        'connected — reliability: ${client.reliability.name}, '
        'max datagram: ${client.datagrams.maxDatagramSize} B',
      );

      // Unreliable, unordered datagrams.
      final datagram = client.datagrams.readable.first;
      await client.datagrams.write(utf8.encode('ping via datagram'));
      _note('datagram echo: ${utf8.decode(await datagram)}');

      // A reliable, ordered bidirectional stream.
      final stream = await client.createBidirectionalStream();
      await stream.writable.write(utf8.encode('hello over a stream'));
      await stream.writable.close();
      final echo = await stream.readable.toBytes();
      _note('stream echo: ${utf8.decode(echo)}');

      await client.close(const WebTransportCloseInfo(closeCode: 0));
      _note('closed');

      if (mounted) setState(() => _status = 'ok');
    } on Object catch (error) {
      _note('failed: $error');
      if (mounted) setState(() => _status = 'failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('webtransport')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('status: $_status', style: const TextStyle(fontSize: 20)),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: _log.length,
                  itemBuilder: (context, index) => Text(_log[index]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
