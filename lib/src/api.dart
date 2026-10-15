/// Layer 4 — the platform neutral WebTransport contract.
///
/// Everything in this file mirrors the browser
/// [WebTransport API](https://w3c.github.io/webtransport/) so the same code can
/// run against the native backend (Rust `wtransport` through
/// `dart:ffi`) and against the browser implementation (`dart:js_interop`).
///
/// Divergences from the browser API are called out explicitly; the two that
/// matter are:
///
///  * Dart has no `WritableStream`, so a send stream is a small object with
///    `write`/`close` methods returning `Future`s instead of a `getWriter()`
///    handshake.
///  * `ReadableStream` maps onto a Dart [Stream], so a receive stream is
///    consumed through [WebTransportReceiveStream.bytes] or
///    [WebTransportReceiveStream.read].
library;

import 'dart:async';
import 'dart:typed_data';

/// Congestion control hint, mirroring `WebTransportCongestionControl`.
enum WebTransportCongestionControl {
  /// `"default"`.
  defaultPolicy('default'),

  /// `"low-latency"`.
  lowLatency('low-latency'),

  /// `"throughput"`.
  throughput('throughput');

  const WebTransportCongestionControl(this.wireName);

  /// The identifier used by the browser API.
  final String wireName;
}

/// Mirrors `WebTransportReliabilityMode`.
enum WebTransportReliabilityMode {
  /// `"pending"` — the handshake has not settled yet.
  pending,

  /// `"reliable-only"` — only reliable streams are available.
  reliableOnly,

  /// `"supports-unreliable"` — datagrams are available too.
  supportsUnreliable,
}

/// Mirrors `WebTransportErrorSource`.
enum WebTransportErrorSource {
  /// `"stream"`.
  stream,

  /// `"session"`.
  session,

  /// `"unknown"`.
  unknown,
}

/// Mirrors `WebTransportHash`.
final class WebTransportHash {
  const WebTransportHash({this.algorithm = 'sha-256', required this.value});

  /// Hash algorithm; only `"sha-256"` is supported.
  final String algorithm;

  /// The digest bytes.
  final List<int> value;
}

/// Mirrors `WebTransportOptions`.
final class WebTransportOptions {
  const WebTransportOptions({
    this.allowPooling = false,
    this.requireUnreliable = false,
    this.congestionControl = WebTransportCongestionControl.defaultPolicy,
    this.serverCertificateHashes = const <WebTransportHash>[],
  });

  /// Allows the session to share a connection with other sessions.
  ///
  /// Ignored by the native backend, which always uses a dedicated QUIC
  /// connection.
  final bool allowPooling;

  /// Requires the connection to support unreliable datagrams.
  final bool requireUnreliable;

  /// Congestion control hint.
  final WebTransportCongestionControl congestionControl;

  /// Certificates the client is willing to accept, identified by the SHA-256
  /// digest of their DER encoding.
  ///
  /// This is how a browser (and this package) connects to a server using a
  /// self-signed certificate without disabling verification entirely.
  final List<WebTransportHash> serverCertificateHashes;
}

/// Mirrors `WebTransportCloseInfo`.
final class WebTransportCloseInfo {
  const WebTransportCloseInfo({this.closeCode = 0, this.reason = ''});

  /// Application close code.
  final int closeCode;

  /// Application close reason.
  final String reason;
}

/// Mirrors `WebTransportSendStreamOptions`.
final class WebTransportSendStreamOptions {
  const WebTransportSendStreamOptions({this.sendOrder});

  /// Relative send order; higher values are transmitted first.
  final int? sendOrder;
}

/// Mirrors `WebTransportError`.
final class WebTransportError implements Exception {
  const WebTransportError({
    this.source = WebTransportErrorSource.unknown,
    this.streamErrorCode,
    this.message = '',
  });

  /// Where the failure originated.
  final WebTransportErrorSource source;

  /// The application error code carried by a stream reset/stop, when any.
  final int? streamErrorCode;

  /// Human readable description.
  final String message;

  @override
  String toString() {
    final code = streamErrorCode == null ? '' : ' (code $streamErrorCode)';
    return 'WebTransportError(${source.name})$code: $message';
  }
}

/// A subset of `WebTransportStats`.
///
/// The native backend reports what QUIC exposes through `quinn`; counters that
/// it cannot know stay zero rather than being guessed.
final class WebTransportStats {
  const WebTransportStats({
    this.timestamp = Duration.zero,
    this.minRtt = Duration.zero,
    this.smoothedRtt = Duration.zero,
    this.bytesSent = 0,
    this.bytesReceived = 0,
    this.packetsSent = 0,
    this.packetsReceived = 0,
    this.numDatagramsSent = 0,
    this.numDatagramsReceived = 0,
    this.numOutgoingStreamsCreated = 0,
    this.numIncomingStreamsCreated = 0,
  });

  /// Monotonic timestamp of the measurement.
  final Duration timestamp;

  /// Minimum observed round-trip time.
  final Duration minRtt;

  /// Smoothed round-trip time.
  final Duration smoothedRtt;

  /// Bytes sent over the session.
  final int bytesSent;

  /// Bytes received over the session.
  final int bytesReceived;

  /// Packets sent.
  final int packetsSent;

  /// Packets received.
  final int packetsReceived;

  /// Datagrams sent.
  final int numDatagramsSent;

  /// Datagrams received.
  final int numDatagramsReceived;

  /// Streams opened by this endpoint.
  final int numOutgoingStreamsCreated;

  /// Streams opened by the peer.
  final int numIncomingStreamsCreated;

  @override
  String toString() =>
      'WebTransportStats(rtt: $smoothedRtt, sent: $bytesSent, '
      'received: $bytesReceived)';
}

/// The writing half of a stream, in place of the browser `WritableStream`.
abstract interface class WebTransportSendStream {
  /// Relative send order; higher values are transmitted first.
  int? get sendOrder;

  set sendOrder(int? value);

  /// Writes `data`, completing once the transport accepted all of it.
  Future<void> write(List<int> data);

  /// Gracefully finishes the stream.
  Future<void> close();

  /// Aborts the stream with an application error code, dropping buffered data.
  Future<void> abort([int errorCode = 0]);
}

/// The reading half of a stream, in place of the browser `ReadableStream`.
abstract interface class WebTransportReceiveStream {
  /// The bytes of this stream.
  ///
  /// Single subscription, like a `ReadableStream` reader. Pausing the
  /// subscription applies back-pressure to the peer.
  Stream<Uint8List> get bytes;

  /// Reads the next chunk, or `null` once the peer finished the stream.
  Future<Uint8List?> read();

  /// Cancels the stream, telling the peer to stop sending.
  Future<void> cancel([int errorCode = 0]);
}

/// Convenience helpers shared by every backend.
extension WebTransportReceiveStreamX on WebTransportReceiveStream {
  /// Drains the stream into a single buffer.
  Future<Uint8List> toBytes() async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in bytes) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

/// Mirrors `WebTransportBidirectionalStream`.
abstract interface class WebTransportBidirectionalStream {
  /// Data sent by the peer.
  WebTransportReceiveStream get readable;

  /// Data sent to the peer.
  WebTransportSendStream get writable;
}

/// Mirrors `WebTransportDatagramDuplexStream`.
abstract interface class WebTransportDatagramDuplexStream {
  /// Unreliable, unordered messages sent by the peer.
  Stream<Uint8List> get readable;

  /// Sends one datagram. Throws when the payload exceeds [maxDatagramSize].
  Future<void> write(List<int> data);

  /// Largest payload the connection currently accepts.
  int get maxDatagramSize;
}

/// Mirrors the browser `WebTransport` interface.
abstract interface class WebTransport {
  /// Completes once the session is established, or fails with a
  /// [WebTransportError] (or a `WebTransportException` on the native backend).
  Future<void> get ready;

  /// Completes once the session is closed from either side.
  Future<void> get closed;

  /// Unreliable, unordered messages.
  WebTransportDatagramDuplexStream get datagrams;

  /// Opens a reliable, ordered bidirectional stream.
  Future<WebTransportBidirectionalStream> createBidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]);

  /// Opens a reliable, ordered unidirectional stream.
  Future<WebTransportSendStream> createUnidirectionalStream([
    WebTransportSendStreamOptions? options,
  ]);

  /// Streams opened by the peer.
  Stream<WebTransportBidirectionalStream> get incomingBidirectionalStreams;

  /// Streams opened by the peer.
  Stream<WebTransportReceiveStream> get incomingUnidirectionalStreams;

  /// Whether the session supports unreliable transport.
  WebTransportReliabilityMode get reliability;

  /// The congestion control policy in use.
  WebTransportCongestionControl get congestionControl;

  /// Closes the session.
  Future<void> close([WebTransportCloseInfo? closeInfo]);

  /// Session statistics.
  Future<WebTransportStats> getStats();
}
