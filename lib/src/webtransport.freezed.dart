// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'webtransport.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$Error {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Error);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'Error()';
}


}

/// @nodoc
class $ErrorCopyWith<$Res>  {
$ErrorCopyWith(Error _, $Res Function(Error) __);
}


/// Adds pattern-matching-related methods to [Error].
extension ErrorPatterns on Error {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( Error_Syntax value)?  syntax,TResult Function( Error_TrustedCerts value)?  trustedCerts,TResult Function( Error_Connect value)?  connect,TResult Function( Error_OpeningStream value)?  openingStream,TResult Function( Error_Stream value)?  stream,TResult Function( Error_Datagram value)?  datagram,TResult Function( Error_Close value)?  close,required TResult orElse(),}){
final _that = this;
switch (_that) {
case Error_Syntax() when syntax != null:
return syntax(_that);case Error_TrustedCerts() when trustedCerts != null:
return trustedCerts(_that);case Error_Connect() when connect != null:
return connect(_that);case Error_OpeningStream() when openingStream != null:
return openingStream(_that);case Error_Stream() when stream != null:
return stream(_that);case Error_Datagram() when datagram != null:
return datagram(_that);case Error_Close() when close != null:
return close(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( Error_Syntax value)  syntax,required TResult Function( Error_TrustedCerts value)  trustedCerts,required TResult Function( Error_Connect value)  connect,required TResult Function( Error_OpeningStream value)  openingStream,required TResult Function( Error_Stream value)  stream,required TResult Function( Error_Datagram value)  datagram,required TResult Function( Error_Close value)  close,}){
final _that = this;
switch (_that) {
case Error_Syntax():
return syntax(_that);case Error_TrustedCerts():
return trustedCerts(_that);case Error_Connect():
return connect(_that);case Error_OpeningStream():
return openingStream(_that);case Error_Stream():
return stream(_that);case Error_Datagram():
return datagram(_that);case Error_Close():
return close(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( Error_Syntax value)?  syntax,TResult? Function( Error_TrustedCerts value)?  trustedCerts,TResult? Function( Error_Connect value)?  connect,TResult? Function( Error_OpeningStream value)?  openingStream,TResult? Function( Error_Stream value)?  stream,TResult? Function( Error_Datagram value)?  datagram,TResult? Function( Error_Close value)?  close,}){
final _that = this;
switch (_that) {
case Error_Syntax() when syntax != null:
return syntax(_that);case Error_TrustedCerts() when trustedCerts != null:
return trustedCerts(_that);case Error_Connect() when connect != null:
return connect(_that);case Error_OpeningStream() when openingStream != null:
return openingStream(_that);case Error_Stream() when stream != null:
return stream(_that);case Error_Datagram() when datagram != null:
return datagram(_that);case Error_Close() when close != null:
return close(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String by,  String reason)?  syntax,TResult Function( String reason)?  trustedCerts,TResult Function( String reason)?  connect,TResult Function( String reason)?  openingStream,TResult Function( String reason)?  stream,TResult Function( String reason)?  datagram,TResult Function( String field0)?  close,required TResult orElse(),}) {final _that = this;
switch (_that) {
case Error_Syntax() when syntax != null:
return syntax(_that.by,_that.reason);case Error_TrustedCerts() when trustedCerts != null:
return trustedCerts(_that.reason);case Error_Connect() when connect != null:
return connect(_that.reason);case Error_OpeningStream() when openingStream != null:
return openingStream(_that.reason);case Error_Stream() when stream != null:
return stream(_that.reason);case Error_Datagram() when datagram != null:
return datagram(_that.reason);case Error_Close() when close != null:
return close(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String by,  String reason)  syntax,required TResult Function( String reason)  trustedCerts,required TResult Function( String reason)  connect,required TResult Function( String reason)  openingStream,required TResult Function( String reason)  stream,required TResult Function( String reason)  datagram,required TResult Function( String field0)  close,}) {final _that = this;
switch (_that) {
case Error_Syntax():
return syntax(_that.by,_that.reason);case Error_TrustedCerts():
return trustedCerts(_that.reason);case Error_Connect():
return connect(_that.reason);case Error_OpeningStream():
return openingStream(_that.reason);case Error_Stream():
return stream(_that.reason);case Error_Datagram():
return datagram(_that.reason);case Error_Close():
return close(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String by,  String reason)?  syntax,TResult? Function( String reason)?  trustedCerts,TResult? Function( String reason)?  connect,TResult? Function( String reason)?  openingStream,TResult? Function( String reason)?  stream,TResult? Function( String reason)?  datagram,TResult? Function( String field0)?  close,}) {final _that = this;
switch (_that) {
case Error_Syntax() when syntax != null:
return syntax(_that.by,_that.reason);case Error_TrustedCerts() when trustedCerts != null:
return trustedCerts(_that.reason);case Error_Connect() when connect != null:
return connect(_that.reason);case Error_OpeningStream() when openingStream != null:
return openingStream(_that.reason);case Error_Stream() when stream != null:
return stream(_that.reason);case Error_Datagram() when datagram != null:
return datagram(_that.reason);case Error_Close() when close != null:
return close(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class Error_Syntax extends Error {
  const Error_Syntax({required this.by, required this.reason}): super._();
  

 final  String by;
 final  String reason;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Error_SyntaxCopyWith<Error_Syntax> get copyWith => _$Error_SyntaxCopyWithImpl<Error_Syntax>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Error_Syntax&&(identical(other.by, by) || other.by == by)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,by,reason);

@override
String toString() {
  return 'Error.syntax(by: $by, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $Error_SyntaxCopyWith<$Res> implements $ErrorCopyWith<$Res> {
  factory $Error_SyntaxCopyWith(Error_Syntax value, $Res Function(Error_Syntax) _then) = _$Error_SyntaxCopyWithImpl;
@useResult
$Res call({
 String by, String reason
});




}
/// @nodoc
class _$Error_SyntaxCopyWithImpl<$Res>
    implements $Error_SyntaxCopyWith<$Res> {
  _$Error_SyntaxCopyWithImpl(this._self, this._then);

  final Error_Syntax _self;
  final $Res Function(Error_Syntax) _then;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? by = null,Object? reason = null,}) {
  return _then(Error_Syntax(
by: null == by ? _self.by : by // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Error_TrustedCerts extends Error {
  const Error_TrustedCerts({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Error_TrustedCertsCopyWith<Error_TrustedCerts> get copyWith => _$Error_TrustedCertsCopyWithImpl<Error_TrustedCerts>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Error_TrustedCerts&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'Error.trustedCerts(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $Error_TrustedCertsCopyWith<$Res> implements $ErrorCopyWith<$Res> {
  factory $Error_TrustedCertsCopyWith(Error_TrustedCerts value, $Res Function(Error_TrustedCerts) _then) = _$Error_TrustedCertsCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$Error_TrustedCertsCopyWithImpl<$Res>
    implements $Error_TrustedCertsCopyWith<$Res> {
  _$Error_TrustedCertsCopyWithImpl(this._self, this._then);

  final Error_TrustedCerts _self;
  final $Res Function(Error_TrustedCerts) _then;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(Error_TrustedCerts(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Error_Connect extends Error {
  const Error_Connect({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Error_ConnectCopyWith<Error_Connect> get copyWith => _$Error_ConnectCopyWithImpl<Error_Connect>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Error_Connect&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'Error.connect(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $Error_ConnectCopyWith<$Res> implements $ErrorCopyWith<$Res> {
  factory $Error_ConnectCopyWith(Error_Connect value, $Res Function(Error_Connect) _then) = _$Error_ConnectCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$Error_ConnectCopyWithImpl<$Res>
    implements $Error_ConnectCopyWith<$Res> {
  _$Error_ConnectCopyWithImpl(this._self, this._then);

  final Error_Connect _self;
  final $Res Function(Error_Connect) _then;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(Error_Connect(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Error_OpeningStream extends Error {
  const Error_OpeningStream({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Error_OpeningStreamCopyWith<Error_OpeningStream> get copyWith => _$Error_OpeningStreamCopyWithImpl<Error_OpeningStream>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Error_OpeningStream&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'Error.openingStream(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $Error_OpeningStreamCopyWith<$Res> implements $ErrorCopyWith<$Res> {
  factory $Error_OpeningStreamCopyWith(Error_OpeningStream value, $Res Function(Error_OpeningStream) _then) = _$Error_OpeningStreamCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$Error_OpeningStreamCopyWithImpl<$Res>
    implements $Error_OpeningStreamCopyWith<$Res> {
  _$Error_OpeningStreamCopyWithImpl(this._self, this._then);

  final Error_OpeningStream _self;
  final $Res Function(Error_OpeningStream) _then;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(Error_OpeningStream(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Error_Stream extends Error {
  const Error_Stream({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Error_StreamCopyWith<Error_Stream> get copyWith => _$Error_StreamCopyWithImpl<Error_Stream>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Error_Stream&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'Error.stream(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $Error_StreamCopyWith<$Res> implements $ErrorCopyWith<$Res> {
  factory $Error_StreamCopyWith(Error_Stream value, $Res Function(Error_Stream) _then) = _$Error_StreamCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$Error_StreamCopyWithImpl<$Res>
    implements $Error_StreamCopyWith<$Res> {
  _$Error_StreamCopyWithImpl(this._self, this._then);

  final Error_Stream _self;
  final $Res Function(Error_Stream) _then;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(Error_Stream(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Error_Datagram extends Error {
  const Error_Datagram({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Error_DatagramCopyWith<Error_Datagram> get copyWith => _$Error_DatagramCopyWithImpl<Error_Datagram>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Error_Datagram&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'Error.datagram(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $Error_DatagramCopyWith<$Res> implements $ErrorCopyWith<$Res> {
  factory $Error_DatagramCopyWith(Error_Datagram value, $Res Function(Error_Datagram) _then) = _$Error_DatagramCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$Error_DatagramCopyWithImpl<$Res>
    implements $Error_DatagramCopyWith<$Res> {
  _$Error_DatagramCopyWithImpl(this._self, this._then);

  final Error_Datagram _self;
  final $Res Function(Error_Datagram) _then;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(Error_Datagram(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Error_Close extends Error {
  const Error_Close(this.field0): super._();
  

 final  String field0;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Error_CloseCopyWith<Error_Close> get copyWith => _$Error_CloseCopyWithImpl<Error_Close>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Error_Close&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'Error.close(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $Error_CloseCopyWith<$Res> implements $ErrorCopyWith<$Res> {
  factory $Error_CloseCopyWith(Error_Close value, $Res Function(Error_Close) _then) = _$Error_CloseCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$Error_CloseCopyWithImpl<$Res>
    implements $Error_CloseCopyWith<$Res> {
  _$Error_CloseCopyWithImpl(this._self, this._then);

  final Error_Close _self;
  final $Res Function(Error_Close) _then;

/// Create a copy of Error
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(Error_Close(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
