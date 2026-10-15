// Regenerates the two generated artifacts of this package:
//
//   1. `src/flutter_webtransport.h` - the C header, emitted by cbindgen from
//      the Rust sources in `rust/src/` (the Rust crate is the source of truth).
//   2. `lib/flutter_webtransport_bindings_generated.dart` - the Dart FFI
//      bindings, emitted by `package:ffigen` from that header.
//
// Usage:
//
//     dart run tool/generate_bindings.dart [--libclang=<dir>]
//
// `ffigen` needs `libclang`. This script locates it automatically (standard
// LLVM installs, a Visual Studio LLVM toolset, `where clang`, the
// `LIBCLANG_PATH` environment variable or an explicit `--libclang=<dir>`),
// writes a machine specific ffigen config into `.dart_tool/` and runs ffigen
// against it. That keeps the checked-in `ffigen.yaml` free of absolute paths.

import 'dart:io';

const String _headerPath = 'src/flutter_webtransport.h';
const String _ffigenConfig = 'ffigen.yaml';
const String _localFfigenConfig = '.dart_tool/ffigen.local.yaml';

Future<int> main(List<String> args) async {
  final root = Directory.current.path;
  final explicitLibclang = _parseOption(args, '--libclang');

  stdout.writeln('==> cbindgen: generating $_headerPath');
  final cbindgenExit = await _run(
    _which('cbindgen') ?? 'cbindgen',
    <String>[
      '--config',
      'cbindgen.toml',
      '--crate',
      'webtransport',
      '--output',
      '../$_headerPath',
    ],
    workingDirectory: '$root/rust',
  );
  if (cbindgenExit != 0) {
    stderr.writeln('cbindgen failed with exit code $cbindgenExit');
    return cbindgenExit;
  }

  final libclangLibrary = findLibclangLibrary(explicit: explicitLibclang);
  if (libclangLibrary == null) {
    stderr.writeln(
      'Could not locate libclang.\n'
      'Install LLVM (https://releases.llvm.org/) or point this script at it:\n'
      r'    dart run tool/generate_bindings.dart --libclang="C:\Program Files\LLVM"',
    );
    return 1;
  }
  stdout.writeln('==> ffigen: libclang found at $libclangLibrary');

  final base = await File('$root/$_ffigenConfig').readAsString();
  // ffigen resolves relative paths against the directory of the config file, so
  // the copy living in `.dart_tool/` needs absolute paths.
  final patched =
      '${_absolutizePaths(base, root)}\n'
      '# Injected by tool/generate_bindings.dart (machine specific).\n'
      '# ffigen accepts a full path to the libclang library here.\n'
      'llvm-path:\n'
      "  - '${libclangLibrary.replaceAll("'", "''")}'\n";
  final localFile = File('$root/$_localFfigenConfig');
  await localFile.parent.create(recursive: true);
  await localFile.writeAsString(patched);

  stdout.writeln('==> ffigen: generating the Dart bindings');
  final ffigenExit = await _run(
    Platform.resolvedExecutable,
    <String>['run', 'ffigen', '--config', _localFfigenConfig],
    workingDirectory: root,
  );
  if (ffigenExit != 0) {
    stderr.writeln('ffigen failed with exit code $ffigenExit');
    return ffigenExit;
  }

  stdout.writeln('==> done');
  return 0;
}

/// Reads a `--name=value` style option.
String? _parseOption(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('$name=')) return arg.substring(name.length + 1);
  }
  return null;
}

/// Rewrites every relative path in the ffigen config to an absolute one.
///
/// `ffigen.yaml` documents its paths relative to the package root; the copy this
/// script hands to ffigen lives in `.dart_tool/`, where relative paths would
/// resolve to the wrong directory.
String _absolutizePaths(String yaml, String root) {
  String absolute(String value) {
    if (value.startsWith('/') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
        value.startsWith(r'\\')) {
      return value;
    }
    return '$root/$value';
  }

  var result = yaml.replaceAllMapped(
    RegExp(r"^(output:\s*)'([^']+)'", multiLine: true),
    (match) => "${match.group(1)}'${absolute(match.group(2)!)}'",
  );
  result = result.replaceAllMapped(
    RegExp(r"^(\s*-\s*)'([^']+)'", multiLine: true),
    (match) => "${match.group(1)}'${absolute(match.group(2)!)}'",
  );
  return result;
}

/// Finds the `libclang` shared library.
///
/// Exposed (non-private) so that it can be unit tested.
String? findLibclangLibrary({String? explicit}) {
  final libclangName = switch (Platform.operatingSystem) {
    'windows' => 'libclang.dll',
    'macos' => 'libclang.dylib',
    _ => 'libclang.so',
  };

  bool looksLikeLibclang(String name) {
    final lower = name.toLowerCase();
    if (!lower.contains('libclang')) return false;
    return lower.endsWith('.dll') ||
        lower.endsWith('.so') ||
        lower.endsWith('.dylib') ||
        lower.contains('.so.');
  }

  /// Returns the library inside `dir` (or `dir/bin`, `dir/lib`), if present.
  String? libraryIn(String dir) {
    final candidates = <String>[
      dir,
      '$dir${Platform.pathSeparator}bin',
      '$dir${Platform.pathSeparator}lib',
    ];
    for (final candidate in candidates) {
      final directory = Directory(candidate);
      if (!directory.existsSync()) continue;
      try {
        for (final entity in directory.listSync()) {
          if (entity is File &&
              entity.uri.pathSegments.last.toLowerCase() == libclangName) {
            return entity.path;
          }
        }
        for (final entity in directory.listSync()) {
          if (entity is File &&
              looksLikeLibclang(entity.uri.pathSegments.last)) {
            return entity.path;
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  final candidates = <String>[];
  if (explicit != null && explicit.isNotEmpty) candidates.add(explicit);
  final fromEnvironment = Platform.environment['LIBCLANG_PATH'];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    final asFile = File(fromEnvironment);
    candidates.add(asFile.existsSync() ? asFile.parent.path : fromEnvironment);
  }
  candidates
    ..addAll(_defaultCandidates())
    ..addAll(_clangOnPath());

  for (final candidate in candidates) {
    final library = libraryIn(candidate);
    if (library != null) return library;
  }

  // `clang -print-file-name=<lib>` as a last resort.
  final clang = _which('clang');
  if (clang != null) {
    final result = Process.runSync(clang, <String>[
      '-print-file-name=$libclangName',
    ]);
    if (result.exitCode == 0) {
      final printed = (result.stdout as String).trim();
      final asFile = File(printed);
      if (printed.isNotEmpty && asFile.existsSync()) return asFile.path;
      final library = libraryIn(printed);
      if (library != null) return library;
    }
  }
  return null;
}

/// Platform specific default install locations.
List<String> _defaultCandidates() {
  if (Platform.isWindows) {
    final programFiles =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programFilesX86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    return <String>[
      '$programFiles\\LLVM\\bin',
      '$programFilesX86\\LLVM\\bin',
      ..._visualStudioLlvmDirs(),
    ];
  }
  if (Platform.isMacOS) {
    return const <String>[
      '/Library/Developer/CommandLineTools/usr/lib',
      '/opt/homebrew/opt/llvm/lib',
      '/usr/local/opt/llvm/lib',
      '/usr/local/lib',
    ];
  }
  return const <String>[
    '/usr/lib/llvm-20/lib',
    '/usr/lib/llvm-19/lib',
    '/usr/lib/llvm-18/lib',
    '/usr/lib/llvm-17/lib',
    '/usr/lib/llvm-16/lib',
    '/usr/lib/x86_64-linux-gnu',
    '/usr/lib',
    '/usr/lib64',
  ];
}

/// LLVM toolset directories shipped with Visual Studio, if installed.
List<String> _visualStudioLlvmDirs() {
  final directories = <String>[];
  final vswhere = File(
    '${Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)'}'
    r'\Microsoft Visual Studio\Installer\vswhere.exe',
  );
  final roots = <String>[];
  if (vswhere.existsSync()) {
    final result = Process.runSync(vswhere.path, <String>[
      '-latest',
      '-products',
      '*',
      '-property',
      'installationPath',
    ]);
    if (result.exitCode == 0) {
      final path = (result.stdout as String).trim();
      if (path.isNotEmpty) roots.add(path);
    }
  }
  if (Platform.environment['VSINSTALLDIR'] case final value?
      when value.isNotEmpty) {
    roots.add(value);
  }

  for (final root in roots) {
    for (final arch in const <String>['x64', 'ARM64', 'x86']) {
      directories.add('$root\\VC\\Tools\\Llvm\\$arch\\bin');
    }
    directories.add('$root\\VC\\Tools\\Llvm\\bin');
  }
  return directories;
}

/// Directories of every `clang` found on `PATH`.
List<String> _clangOnPath() {
  final directories = <String>[];
  for (final name in const <String>['clang', 'clang.exe']) {
    final path = _which(name);
    if (path != null) directories.add(File(path).parent.path);
  }
  return directories;
}

/// Minimal `which`, so that the package needs no extra dependency.
String? _which(String executable) {
  final pathVariable = Platform.environment['PATH'] ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  final suffixes = Platform.isWindows
      ? const <String>['.exe', '.cmd', '.bat', '']
      : const <String>[''];
  for (final entry in pathVariable.split(separator)) {
    if (entry.isEmpty) continue;
    for (final suffix in suffixes) {
      final candidate = File(
        '$entry${Platform.pathSeparator}$executable$suffix',
      );
      if (candidate.existsSync()) return candidate.path;
    }
  }
  return null;
}

Future<int> _run(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}
