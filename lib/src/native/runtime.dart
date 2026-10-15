/// Layer 2 — the asynchronous runtime and the completion pump.
///
/// The Rust side owns a multi-threaded tokio runtime and reports every
/// completion through one callback. This layer:
///
///  * starts/stops that runtime (`wt_runtime_init` / `wt_runtime_shutdown`);
///  * registers a `NativeCallable.listener`, the only callback in `dart:ffi`
///    that may be invoked from an arbitrary foreign thread;
///  * correlates completions with the Dart code that issued them;
///  * drains the native event batch exactly once, converting every entry into a
///    Dart value before the batch is released.
///
/// No call made from here blocks: every operation returns a status immediately
/// and reports its outcome through the callback.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../webtransport_bindings_generated.dart' as b;
import 'memory.dart';

/// Owns the native runtime and routes completions to their Dart completers.
final class WebTransportRuntime {
  WebTransportRuntime._();

  /// One runtime per process: the native library exposes a single event sink.
  static final WebTransportRuntime instance = WebTransportRuntime._();

  final Map<int, void Function(NativeEvent)> _pending =
      <int, void Function(NativeEvent)>{};
  final StreamController<String> _logs = StreamController<String>.broadcast(
    sync: true,
  );

  NativeCallable<b.wt_events_cb_tFunction>? _callback;
  int _nextOpId = 1;
  bool _started = false;

  /// Diagnostics emitted by the native layer (`WT_OP_LOG` events).
  Stream<String> get logs => _logs.stream;

  /// Whether the native runtime is running in this isolate.
  bool get isRunning => _started;

  /// Starts the runtime. Calling it more than once is a no-op.
  void start({int workerThreads = 0, int dispatchBatchMax = 64}) {
    if (_started) return;
    final callback = NativeCallable<b.wt_events_cb_tFunction>.listener(
      _onBatch,
    );
    final config = calloc<b.wt_runtime_config_t>();
    try {
      config.ref
        ..struct_size = sizeOf<b.wt_runtime_config_t>()
        ..worker_threads = workerThreads
        ..dispatch_batch_max = dispatchBatchMax;
      final status = b.wt_runtime_init(
        config,
        callback.nativeFunction,
        nullptr,
      );
      if (status != b.wt_status_t.WT_OK) {
        callback.close();
        throw WebTransportException(
          status.value,
          'could not start the webtransport runtime',
          operation: 'wt_runtime_init',
        );
      }
    } finally {
      calloc.free(config);
    }
    _callback = callback;
    _started = true;
  }

  /// Stops the runtime and fails every pending completion.
  void shutdown() {
    if (!_started) return;
    b.wt_runtime_shutdown();
    _started = false;
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final handler in pending) {
      handler(
        NativeEvent(
          opId: 0,
          kind: b.wt_op_t.WT_OP_NONE,
          status: b.wt_status_t.WT_ERR_NO_RUNTIME.value,
          handle: nullptr,
          handle2: nullptr,
          aux: 0,
          data: null,
          message: 'the runtime was shut down',
        ),
      );
    }
    _callback?.close();
    _callback = null;
  }

  /// Blocks until all in-flight operations completed, or the timeout expires.
  bool waitIdle({Duration timeout = const Duration(seconds: 5)}) =>
      b.wt_runtime_wait_idle(timeout.inMilliseconds) == b.wt_status_t.WT_OK;

  /// Registers a completion handler and returns its correlation id.
  int register(void Function(NativeEvent) handler) {
    final id = _nextOpId++;
    _pending[id] = handler;
    return id;
  }

  /// Drops a handler (used when starting the operation failed immediately).
  void cancel(int opId) => _pending.remove(opId);

  /// Starts `begin` and completes with the single event it produces.
  Future<NativeEvent> oneShot(
    Object operation,
    b.wt_status_t Function(int opId) begin,
  ) {
    final completer = Completer<NativeEvent>();
    final opId = register(completer.complete);
    try {
      final status = begin(opId);
      if (status != b.wt_status_t.WT_OK) {
        cancel(opId);
        completer.completeError(
          WebTransportException(status.value, 'failed', operation: operation),
        );
      }
    } on Object catch (error, stackTrace) {
      cancel(opId);
      completer.completeError(error, stackTrace);
    }
    return completer.future;
  }

  /// Starts `begin` and reports only its immediate status.
  b.wt_status_t fireAndForget(b.wt_status_t Function(int opId) begin) {
    final opId = register((_) {});
    final status = begin(opId);
    if (status != b.wt_status_t.WT_OK) cancel(opId);
    return status;
  }

  void _onBatch(Pointer<Void> context, Pointer<b.wt_event_batch_t> batch) {
    final count = b.wt_batch_count(batch);
    final events = b.wt_batch_events(batch);
    try {
      for (var index = 0; index < count; index++) {
        final raw = events[index];
        final length = raw.data_len;
        final event = NativeEvent(
          opId: raw.op_id,
          kind: raw.kind,
          status: raw.statusAsInt,
          handle: raw.handle,
          handle2: raw.handle2,
          aux: raw.aux,
          data: length == 0
              ? null
              : Uint8List.fromList(raw.data.asTypedList(length)),
          message: raw.message == nullptr
              ? null
              : raw.message.cast<Utf8>().toDartString(),
        );
        if (event.kind == b.wt_op_t.WT_OP_LOG) {
          if (!_logs.isClosed) _logs.add(event.message ?? '');
          continue;
        }
        _pending.remove(event.opId)?.call(event);
      }
    } finally {
      // Every pointer inside the batch dies here.
      b.wt_batch_free(batch);
    }
  }
}

/// The runtime backing the in-process native implementation.
WebTransportRuntime get nativeRuntime => WebTransportRuntime.instance;
