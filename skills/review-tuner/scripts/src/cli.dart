/// Command-line helpers shared by the review-tuner scripts: argument parsing,
/// the exit-code contract, JSON and file I/O, and the `gh` / `git` runners.
library;

import 'dart:convert';
import 'dart:io';

/// Exit code for a failed step, query, or bad input data (never reported as
/// "no results").
const exitFailure = 1;

/// Exit code for invalid command-line arguments.
const exitBadUsage = 2;

/// Retries for a transient `gh` failure; the backoff grows quadratically.
const _ghRetries = 4;
const _ghBackoffSeconds = 5;

/// Lowercased `gh` stderr fragments that mark a failure as transient.
const _transient = ['rate limit', 'http 5', 'timeout', 'something went wrong'];

/// The running script's usage text, printed with every usage error.
String _usage = '';

/// Thrown by [parseArgs] when `--help` or `-h` is given.
final class _HelpRequested implements Exception {
  const _HelpRequested();
}

bool _isHelp(String arg) => arg == '--help' || arg == '-h';

/// Runs a script's [body] with [usage] as its usage text, turning any
/// unexpected exception into a one-line error and [exitFailure] (instead of
/// a stack trace and exit 255). `--help` or `-h` as the first of [argv], or
/// anywhere [parseArgs] sees it, prints [usage] to stdout and exits 0.
Future<void> guarded(
    String usage, List<String> argv, Future<void> Function() body) async {
  _usage = usage;
  try {
    if (argv.firstOrNull case var first? when _isHelp(first)) {
      throw const _HelpRequested();
    }
    await body();
  } on _HelpRequested {
    stdout.writeln(usage);
  } catch (e) {
    fail('Error: $e');
  }
}

/// Prints [message] and the usage text to stderr and exits with
/// [exitBadUsage]. Only for problems with the command line itself.
Never usageError(String message) {
  stderr
    ..writeln(message)
    ..writeln(_usage);
  exit(exitBadUsage);
}

/// Prints [message] to stderr and exits with [exitFailure]: a failed step or
/// bad input data (including `eval.json`, config, and corpus content).
Never fail(String message) {
  stderr.writeln(message);
  exit(exitFailure);
}

/// Parses `--name value` options (names in [options]) and `--flag` booleans
/// (names in [flags]); any other `--name` is a usage error. Anything not
/// starting with `--` is positional. `--help` or `-h` (not as an option's
/// value) prints the usage text and exits 0 (see [guarded]).
({Map<String, String> options, List<String> positional}) parseArgs(
  List<String> argv, {
  required Set<String> options,
  Set<String> flags = const {},
}) {
  var values = <String, String>{};
  var positional = <String>[];
  for (var i = 0; i < argv.length; i++) {
    var arg = argv[i];
    if (_isHelp(arg)) throw const _HelpRequested();
    if (!arg.startsWith('--')) {
      positional.add(arg);
      continue;
    }
    var name = arg.substring(2);
    if (flags.contains(name)) {
      values[name] = 'true';
    } else if (!options.contains(name)) {
      usageError('Unknown option $arg');
    } else if (i + 1 < argv.length) {
      values[name] = argv[++i];
    } else {
      usageError('Missing value for $arg');
    }
  }
  return (options: values, positional: positional);
}

/// Absolute, normalized path without a trailing slash.
String absPath(String path) {
  var p = File(path).absolute.uri.normalizePath().toFilePath();
  return p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;
}

/// Reads and decodes a JSON file, exiting with [exitFailure] on error.
Object? readJson(String path) {
  var file = File(path);
  if (!file.existsSync()) fail('Missing file: $path');
  try {
    return jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    fail('Invalid JSON in $path: ${e.message}');
  }
}

/// Writes [value] as indented JSON, creating parent directories.
void writeJson(String path, Object? value) =>
    writeText(path, '${const JsonEncoder.withIndent('  ').convert(value)}\n');

/// Writes [text] to [path], creating parent directories.
void writeText(String path, String text) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
}

/// Thrown when an external command (`gh`, `git`) fails.
final class CommandException implements Exception {
  CommandException(this.step, this.message);

  final String step;
  final String message;

  /// Whether `gh` reported that the resource does not exist.
  bool get notFound => message.contains('(HTTP 404)');

  @override
  String toString() => '$step: $message';
}

/// Runs `gh` with [args] and returns its stdout, retrying transient failures
/// (rate limits, HTTP 5xx, timeouts). [step] names the failure.
Future<String> gh(List<String> args, {String? step}) async {
  for (var attempt = 0;; attempt++) {
    var result = await Process.run('gh', args,
        stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.exitCode == 0) return result.stdout as String;
    var err = (result.stderr as String).trim();
    var transient = _transient.any(err.toLowerCase().contains);
    if (!transient || attempt >= _ghRetries) {
      throw CommandException(step ?? 'gh ${args.take(2).join(' ')}', err);
    }
    var wait = _ghBackoffSeconds * (attempt + 1) * (attempt + 1);
    await Future<void>.delayed(Duration(seconds: wait));
  }
}

/// Runs `git` with [args] in [dir] and returns its stdout.
Future<String> git(String dir, List<String> args, {String? step}) async {
  var result = await Process.run('git', args,
      workingDirectory: dir, stdoutEncoding: utf8, stderrEncoding: utf8);
  if (result.exitCode != 0) {
    throw CommandException(
        step ?? 'git ${args.first}', (result.stderr as String).trim());
  }
  return result.stdout as String;
}
