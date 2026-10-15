import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

/// Build hook for the `webtransport` code asset.
///
/// Flutter resolves `LinkModePreference.dynamic` for every target platform, so
/// the resolved link mode is `DynamicLoadingBundled()` and
/// `native_toolchain_rust` builds the `cdylib` from `rust/Cargo.toml` and
/// bundles the resulting dynamic library (`webtransport.dll` /
/// `libwebtransport.so` / `libwebtransport.dylib`) into the application.
///
/// `assetName` is the path (relative to this package) of the Dart file that
/// declares the `@Native` bindings. Together they form the code asset id
/// `package:flutter_webtransport/flutter_webtransport_bindings_generated.dart`,
/// which is exactly what the ffigen output in `lib/` refers to.
///
/// ## Why this hook re-executes itself
///
/// `hooks_runner` runs every build hook with a *filtered* environment: only a
/// white-list of variables (see `includeHookEnvironmentVariable` in
/// `package:hooks_runner`) is forwarded. That list contains `PATH`,
/// `LIBCLANG_PATH`, `TEMP`, ... but **not** `CARGO_HOME` or `RUSTUP_HOME`.
///
/// `native_toolchain_rust` shells out to `rustup`, which resolves both from the
/// environment and otherwise falls back to `%USERPROFILE%\.rustup` /
/// `%USERPROFILE%\.cargo`. On a machine where the developer moved those
/// directories elsewhere (a common setup), the first build would therefore
/// download a second copy of the pinned toolchain into the default location —
/// several gigabytes the developer never asked for.
///
/// Because `Platform.environment` is an unmodifiable snapshot and build hooks
/// cannot influence the environment of `rustup` otherwise, this hook re-executes
/// itself once with the resolved `CARGO_HOME`/`RUSTUP_HOME` added. The child
/// performs the actual build, so *both* the `rustup` and the `cargo` invocations
/// use the developer's own toolchain installation.
void main(List<String> args) async {
  final toolchain = _resolveToolchainEnvironment(_userDefinesFromArgs(args));
  if (toolchain.isNotEmpty &&
      Platform.environment[_reExecMarker] == null &&
      Platform.script.toFilePath().isNotEmpty) {
    exit(await _reExecWithEnvironment(args, toolchain));
  }

  await build(args, (input, output) async {
    // `Logger.detached` avoids the logging hierarchy, which would otherwise
    // require `hierarchicalLoggingEnabled` just to raise the verbosity.
    final logger = Logger.detached('flutter_webtransport/build')
      ..level = Level.ALL
      ..onRecord.listen((record) {
        final sink = record.level >= Level.WARNING ? stderr : stdout;
        sink.writeln('[webtransport] ${record.message}');
      });

    if (!input.config.buildCodeAssets) {
      logger.info('buildCodeAssets is disabled; nothing to build');
      return;
    }

    final codeConfig = input.config.code;
    logger.info(
      'Building the webtransport code asset for '
      '${codeConfig.targetOS.name}/${codeConfig.targetArchitecture.name} '
      '(link mode preference: ${codeConfig.linkModePreference})',
    );

    await RustBuilder(
      assetName: 'flutter_webtransport_bindings_generated.dart',
      cratePath: 'rust',
      // Release by default: the whole point of this package is throughput.
      buildMode: BuildMode.release,
      // Features are declared in `rust/Cargo.toml`; `self-signed` provides the
      // test identities and `dangerous-configuration` the explicit "accept any
      // certificate" client mode. `ring` (no cmake/nasm required) is selected
      // by the crate itself so the hook stays self-contained on every host.
      enableDefaultFeatures: true,
      extraCargoEnvironmentVariables: <String, String>{
        ..._privateTempEnvironment(input, logger),
        ...toolchain,
      },
    ).run(input: input, output: output, logger: logger);
  });
}

// ---------------------------------------------------------------------------
// Toolchain locations
// ---------------------------------------------------------------------------

/// Marker set on the re-executed child so that it never re-executes again.
const String _reExecMarker = 'FLUTTER_WEBTRANSPORT_HOOK_REEXEC';

/// The package name used to read `hooks: user_defines:` overrides.
const String _packageName = 'flutter_webtransport';

/// Resolves the `CARGO_HOME`/`RUSTUP_HOME` values that the hook environment is
/// missing.
///
/// Resolution order:
///   1. the inherited environment (used as is when the hook already has it);
///   2. an explicit override from `hooks: user_defines:`:
///      ```yaml
///      hooks:
///        user_defines:
///          flutter_webtransport:
///            cargo_home: D:\Devel\Rust\Cargo
///            rustup_home: D:\Devel\Rust\Rustup
///      ```
///   3. the value registered for the current Windows user profile.
///
/// Only variables that are *absent* from the environment are returned; they are
/// exactly the ones worth re-executing for.
Map<String, String> _resolveToolchainEnvironment(
  Map<String, Object?> overrides,
) {
  final resolved = <String, String>{};
  for (final name in const <String>['CARGO_HOME', 'RUSTUP_HOME']) {
    if (Platform.environment[name]?.isNotEmpty ?? false) continue;

    var value = overrides[name.toLowerCase()] is String
        ? overrides[name.toLowerCase()]! as String
        : null;
    value ??= _registeredUserEnvironmentVariable(name);
    if (value == null || value.isEmpty) continue;

    final expanded = _expandEnvironmentVariables(value);
    if (!Directory(expanded).existsSync()) continue;
    resolved[name] = expanded;
  }
  return resolved;
}

/// Runs this hook again with `environment` added, inheriting stdio, and returns
/// the child's exit code.
Future<int> _reExecWithEnvironment(
  List<String> args,
  Map<String, String> environment,
) async {
  final executable = Platform.resolvedExecutable;
  final arguments = <String>[
    ...Platform.executableArguments,
    Platform.script.toFilePath(),
    ...args,
  ];
  try {
    final process = await Process.start(
      executable,
      arguments,
      environment: <String, String>{...environment, _reExecMarker: '1'},
      mode: ProcessStartMode.inheritStdio,
    );
    return await process.exitCode;
  } on ProcessException catch (error) {
    stderr.writeln(
      '[webtransport] could not re-execute the hook with '
      '${environment.keys.join(', ')}: $error',
    );
    return 0; // Fall through: the build can still try with the default home.
  }
}

/// Reads `hooks: user_defines: flutter_webtransport:` out of the hook input.
Map<String, Object?> _userDefinesFromArgs(List<String> args) {
  for (final arg in args) {
    if (!arg.startsWith('-config=')) continue;
    final file = File(arg.substring('-config='.length));
    if (!file.existsSync()) return const <String, Object?>{};
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map<String, Object?>) return const <String, Object?>{};
      final defines = json['user_defines'];
      if (defines is! Map) return const <String, Object?>{};
      final packageDefines = defines[_packageName];
      if (packageDefines is! Map) return const <String, Object?>{};
      return packageDefines.cast<String, Object?>();
    } on Object {
      return const <String, Object?>{};
    }
  }
  return const <String, Object?>{};
}

/// Reads a variable from `HKEY_CURRENT_USER\Environment` (Windows only).
String? _registeredUserEnvironmentVariable(String name) {
  if (!Platform.isWindows) return null;
  try {
    final result = Process.runSync('reg', <String>[
      'query',
      r'HKCU\Environment',
      '/v',
      name,
    ]);
    if (result.exitCode != 0) return null;
    for (final line in result.stdout.toString().split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith(name)) continue;
      final parts = trimmed.split(RegExp(r'\s{2,}'));
      if (parts.length < 3) continue;
      final value = parts.sublist(2).join(' ').trim();
      return value.isEmpty ? null : value;
    }
  } on ProcessException {
    return null;
  }
  return null;
}

/// Expands `%NAME%` and `$NAME`/`${NAME}` references from the environment.
String _expandEnvironmentVariables(String value) {
  var expanded = value.replaceAllMapped(
    RegExp(r'%([^%]+)%'),
    (match) => Platform.environment[match.group(1)!] ?? match.group(0)!,
  );
  expanded = expanded.replaceAllMapped(
    RegExp(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?'),
    (match) => Platform.environment[match.group(1)!] ?? match.group(0)!,
  );
  return expanded;
}

// ---------------------------------------------------------------------------
// Private temp directory
// ---------------------------------------------------------------------------

/// Extra environment for the Rust build.
///
/// `ring` compiles C/assembly through the `cc` crate, whose MSVC archiver
/// (`lib.exe`) creates a scratch file in `%TEMP%`. Sandboxed build environments
/// frequently cannot write to the inherited temp directory, which surfaces as
/// `LNK1104: cannot open file '...\lnk{...}.tmp'`. Pointing `TMP`/`TEMP` at a
/// directory owned by this hook makes the build independent of the host
/// configuration and keeps intermediate files inside the build output.
Map<String, String> _privateTempEnvironment(BuildInput input, Logger logger) {
  try {
    final base = input.outputDirectory.toFilePath();
    final separator =
        base.endsWith('/') || base.endsWith('\\') ? '' : Platform.pathSeparator;
    final directory = Directory('$base${separator}tmp')
      ..createSync(recursive: true);
    logger.fine('Using ${directory.path} as TMP/TEMP for the Rust build');
    return <String, String>{'TMP': directory.path, 'TEMP': directory.path};
  } on FileSystemException catch (error) {
    logger.warning(
      'Could not create a private temp directory ($error); '
      'falling back to the inherited TMP/TEMP',
    );
    return const <String, String>{};
  }
}
