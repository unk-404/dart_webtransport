/// Layer 1 — native memory safety.
///
/// This layer owns everything that can go wrong when Dart touches C:
///
///  * turning `wt_status_t` into a typed exception;
///  * marshalling strings and header arrays in and out of native memory;
///  * owning `wt_buffer_t` allocations (and adopting their storage into a
///    `Uint8List` that releases the native memory when it is collected);
///  * copying a `wt_event_t` out of a batch before the batch is released.
///
/// Nothing above this layer performs pointer arithmetic or `malloc`/`calloc`.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../webtransport_bindings_generated.dart' as b;

/// Raised when the native layer reports a non-success status.
final class WebTransportException implements Exception {
  WebTransportException(this.status, this.message, {this.operation});

  /// The raw `wt_status_t` value.
  final int status;

  /// Human readable description reported by the native layer.
  final String message;

  /// The operation that failed, when known.
  final Object? operation;

  /// The parsed status code, when it is one this binding knows about.
  b.wt_status_t? get code {
    try {
      return b.wt_status_t.fromValue(status);
    } on ArgumentError {
      return null;
    }
  }

  /// True when the failure just means "this stream/connection is gone".
  bool get isClosed =>
      status == b.wt_status_t.WT_ERR_NOT_CONNECTED.value ||
      status == b.wt_status_t.WT_ERR_STREAM_CLOSED.value ||
      status == b.wt_status_t.WT_ERR_ENDPOINT_CLOSED.value;

  @override
  String toString() {
    final name = code?.name ?? 'status($status)';
    final subject = operation == null ? '' : ' during $operation';
    final detail = message.isEmpty ? '' : ': $message';
    return 'WebTransportException: $name$subject$detail';
  }
}

/// Throws a [WebTransportException] unless `status` is a success.
void checkStatus(b.wt_status_t status, Object operation) {
  if (status != b.wt_status_t.WT_OK) {
    throw WebTransportException(status.value, 'failed', operation: operation);
  }
}

/// Copies a Dart string into native memory; free it with [freeNativeString].
Pointer<Char> toNativeString(String value) => value.toNativeUtf8().cast();

/// Releases a string produced by [toNativeString].
void freeNativeString(Pointer<Char> pointer) => malloc.free(pointer);

/// A native `wt_header_t` array plus the resources backing it.
typedef NativeHeaders = ({
  Pointer<b.wt_header_t> pointer,
  int length,
  void Function() free,
});

/// Builds a native array of `wt_header_t` for [headers].
NativeHeaders allocHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) {
    return (pointer: nullptr, length: 0, free: () {});
  }
  final names = <Pointer<Char>>[];
  final values = <Pointer<Char>>[];
  final array = calloc<b.wt_header_t>(headers.length);
  var index = 0;
  for (final entry in headers.entries) {
    final name = toNativeString(entry.key);
    final value = toNativeString(entry.value);
    names.add(name);
    values.add(value);
    array[index]
      ..name = name
      ..value = value;
    index++;
  }
  return (
    pointer: array,
    length: headers.length,
    free: () {
      for (final pointer in names) {
        freeNativeString(pointer);
      }
      for (final pointer in values) {
        freeNativeString(pointer);
      }
      calloc.free(array);
    },
  );
}

/// A completion reported by the native layer, copied out of its batch.
///
/// The native batch is released as soon as the callback that delivered it
/// returns, so this type holds plain Dart values only.
final class NativeEvent {
  NativeEvent({
    required this.opId,
    required this.kind,
    required this.status,
    required this.handle,
    required this.handle2,
    required this.aux,
    required this.data,
    required this.message,
  });

  final int opId;
  final b.wt_op_t kind;

  /// Raw `wt_status_t` value.
  final int status;
  final Pointer<Void> handle;
  final Pointer<Void> handle2;
  final int aux;

  /// Payload, when the operation produced one (datagrams, owned reads).
  final Uint8List? data;

  /// Diagnostic text, when the native layer reported one.
  final String? message;

  /// True for `WT_OK` and `WT_EOF`.
  bool get isOk => status >= 0;

  /// True when a read hit the end of the stream.
  bool get isEof => status == b.wt_status_t.WT_EOF.value;

  WebTransportException exception([Object? operation]) =>
      WebTransportException(status, message ?? '', operation: operation);
}

/// Native memory shared with the transport.
///
/// A buffer allocated here can be filled in Dart and handed to
/// [SendStream.writeBuffer] (no Dart-side copy), or passed to
/// [RecvStream.readInto] so the transport writes straight into it.
final class NativeBuffer {
  /// Allocates `capacity` bytes of native memory.
  NativeBuffer(int capacity) : _handle = b.wt_buffer_new(capacity) {
    if (_handle == nullptr) {
      throw WebTransportException(
        b.wt_status_t.WT_ERR_IO.value,
        'could not allocate $capacity bytes',
        operation: 'wt_buffer_new',
      );
    }
  }

  /// Adopts an existing `wt_buffer_t` handle (takes ownership).
  NativeBuffer.adopt(this._handle);

  Pointer<b.wt_buffer_t> _handle;

  /// The underlying handle.
  Pointer<b.wt_buffer_t> get handle => _handle;

  /// Writable start of the allocation.
  Pointer<Uint8> get data => b.wt_buffer_data(_handle);

  /// Allocated capacity in bytes.
  int get capacity => b.wt_buffer_capacity(_handle);

  /// Logical length in bytes.
  int get length => b.wt_buffer_len(_handle);

  set length(int value) => b.wt_buffer_set_len(_handle, value);

  /// A view over the first [length] bytes (no copy).
  Uint8List get bytes => data.asTypedList(length);

  /// Grows the buffer, invalidating previously obtained pointers.
  void reserve(int capacity) =>
      checkStatus(b.wt_buffer_reserve(_handle, capacity), 'wt_buffer_reserve');

  /// Releases the storage. Any in-flight read into it must have completed, and
  /// any list returned by [adoptBuffer] from this buffer must be dropped first.
  void free() {
    if (_handle == nullptr) return;
    b.wt_buffer_free(_handle);
    _handle = nullptr;
  }
}

/// Frees an adopted buffer once the list handed to Dart is collected.
///
/// Isolates share the address space, so a buffer allocated by one isolate may be
/// adopted (and therefore freed) by another; the native handle is reference
/// counted internally.
final Finalizer<Pointer<b.wt_buffer_t>> _bufferReaper =
    Finalizer<Pointer<b.wt_buffer_t>>((handle) => b.wt_buffer_free(handle));

/// Hands the storage of `handle` to Dart and returns a view over `length` bytes.
///
/// The memory is released once the returned list is collected. This is what
/// makes the read path zero-copy: the transport writes directly into the memory
/// Dart then exposes as a `Uint8List`.
Uint8List adoptBuffer(Pointer<b.wt_buffer_t> handle, int length) {
  final view = b.wt_buffer_data(handle).asTypedList(length);
  _bufferReaper.attach(view, handle);
  return view;
}

/// `true` when `pointer` is the null pointer.
bool isNull<T extends NativeType>(Pointer<T> pointer) => pointer == nullptr;
