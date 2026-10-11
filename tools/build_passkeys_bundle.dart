// Builds web/passkeys_bundle.js: the JavaScript SDK that package:passkeys
// needs on web (see docs/PASSKEYS.md).
//
// The SDK isn't published anywhere for current passkeys_web versions, so
// this builds it from the passkeys_web-v<version> tag of
// github.com/corbado/flutter-passkeys, using the passkeys_web version in
// pubspec.lock. It skips the build when web/passkeys_bundle.version already
// matches. Needs git and Node.js (npm) on PATH.
//
// Usage (from anywhere in the project, after `flutter pub get`):
//   dart run tools/build_passkeys_bundle.dart [--force]

import 'dart:io';

const _repo = 'https://github.com/corbado/flutter-passkeys';
const _sdkPath = 'packages/passkeys/passkeys_web/javascript';

Future<void> main(List<String> args) async {
  final force = args.contains('--force');

  final root = _projectRoot();
  if (root == null) {
    _fail("Couldn't find the project's pubspec.yaml.");
    return;
  }
  final bundle = File('${root.path}/web/passkeys_bundle.js');
  final stamp = File('${root.path}/web/passkeys_bundle.version');

  final version = _lockedVersion(File('${root.path}/pubspec.lock'));
  if (version == null) {
    _fail('passkeys_web not found in pubspec.lock. '
        'Run `flutter pub get` first.');
    return;
  }

  if (!force &&
      bundle.existsSync() &&
      stamp.existsSync() &&
      stamp.readAsStringSync().trim() == version) {
    stdout.writeln('web/passkeys_bundle.js is up to date '
        '(passkeys_web $version).');
    return;
  }

  for (final tool in ['git', 'npm']) {
    if (!await _isInstalled(tool)) {
      _fail('`$tool` is needed to build the bundle but was not found.');
      return;
    }
  }

  stdout.writeln('Building web/passkeys_bundle.js for passkeys_web $version…');
  final temp = await Directory.systemTemp.createTemp('passkeys_web_');
  try {
    final src = '${temp.path}/flutter-passkeys';
    await _run(
      'git',
      [
        'clone', '--quiet', '--depth', '1', '--filter=blob:none', '--sparse',
        '--branch', 'passkeys_web-v$version', _repo, src, //
      ],
      hint: 'Check that the tag passkeys_web-v$version exists in $_repo.',
    );
    await _run('git', ['sparse-checkout', 'set', _sdkPath],
        workingDirectory: src);

    final sdk = '$src/$_sdkPath';
    // --ignore-scripts: nothing in the SDK's dependencies needs install
    // scripts, and it keeps third-party code from running here.
    await _run('npm', ['ci', '--ignore-scripts', '--no-audit', '--no-fund'],
        workingDirectory: sdk);
    await _run('npm', ['run', 'build'], workingDirectory: sdk);

    // Copy next to the target, then rename over it, so an interrupted
    // build never leaves a half-written bundle behind. The stamp is written
    // last, so a failed run is retried next time.
    final partial = File('${bundle.path}.partial');
    await File('$sdk/dist/bundle.js').copy(partial.path);
    await partial.rename(bundle.path);
    await stamp.writeAsString('$version\n');
    stdout.writeln('Built web/passkeys_bundle.js (passkeys_web $version).');
  } on _StepFailed catch (error) {
    _fail(error.message);
  } finally {
    await temp.delete(recursive: true);
  }
}

/// The nearest directory with a pubspec.yaml, starting from this script's
/// folder (when run from source) or the working directory.
Directory? _projectRoot() {
  final script = Platform.script;
  var dir = script.scheme == 'file' && script.path.endsWith('.dart')
      ? File.fromUri(script).parent
      : Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

/// The resolved passkeys_web version, e.g. `2.10.1`.
String? _lockedVersion(File lockFile) {
  if (!lockFile.existsSync()) return null;
  final match = RegExp(
    r'^  passkeys_web:\r?\n(?:    .*\r?\n)*?    version: "([^"]+)"',
    multiLine: true,
  ).firstMatch(lockFile.readAsStringSync());
  return match?.group(1);
}

Future<bool> _isInstalled(String tool) async {
  try {
    final result = await Process.run(tool, ['--version'],
        runInShell: Platform.isWindows);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Runs a command with its output shown, throwing [_StepFailed] if it
/// fails.
Future<void> _run(String executable, List<String> args,
    {String? workingDirectory, String? hint}) async {
  final process = await Process.start(executable, args,
      workingDirectory: workingDirectory,
      // npm is a .cmd script on Windows, which needs a shell to start.
      runInShell: Platform.isWindows,
      mode: ProcessStartMode.inheritStdio);
  final code = await process.exitCode;
  if (code != 0) {
    throw _StepFailed('`$executable ${args.join(' ')}` failed '
        '(exit code $code).${hint == null ? '' : ' $hint'}');
  }
}

void _fail(String message) {
  stderr.writeln('Error: $message');
  exitCode = 1;
}

class _StepFailed implements Exception {
  const _StepFailed(this.message);

  final String message;
}
