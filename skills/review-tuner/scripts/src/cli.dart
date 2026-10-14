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

/// Retries for a transient `gh` failure; the backoff doubles (2, 4, 8 s).
const _ghRetries = 3;
const _ghBackoffSeconds = 2;

/// A `gh` call that runs longer than this is killed and counts as transient.
const ghTimeout = Duration(seconds: 120);

/// Lowercased `gh` stderr fragments that mark a failure as transient. The
/// primary rate limit ("API rate limit exceeded") is not one: it resets
/// within the hour, so retrying only delays the failure.
const _transient = [
  'secondary rate limit',
  'http 5',
  'timeout',
  'timed out',
  'something went wrong',
  'connection reset',
];

/// What a primary rate limit means for the user, added to its error.
const _rateLimitHint = ' [not retried: the primary rate limit resets within '
    'the hour; "Authenticated requests" in the message means gh has no valid '
    'token in this shell (sandboxed shells often lack it): check '
    '`gh auth status`]';

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
/// (secondary rate limits, HTTP 5xx, timeouts) a few times with a short
/// backoff, at most [retries] times. Each attempt is killed after [timeout].
/// [step] names the failure.
Future<String> gh(
  List<String> args, {
  String? step,
  Duration timeout = ghTimeout,
  int retries = _ghRetries,
}) async {
  for (var attempt = 0;; attempt++) {
    var result = await _run('gh', args, timeout: timeout);
    if (result.exitCode == 0) return result.stdout;
    var err = result.stderr;
    var lower = err.toLowerCase();
    var transient = _transient.any(lower.contains);
    if (!transient || attempt >= retries) {
      if (lower.contains('rate limit') && !lower.contains('secondary')) {
        err += _rateLimitHint;
      }
      throw CommandException(step ?? 'gh ${args.take(2).join(' ')}', err);
    }
    await Future<void>.delayed(Duration(seconds: _ghBackoffSeconds << attempt));
  }
}

/// Runs `git` with [args] in [dir] and returns its stdout. With a [timeout],
/// a slower `git` is killed and fails. Never prompts for credentials.
Future<String> git(String dir, List<String> args,
    {String? step, Duration? timeout}) async {
  var result = await _run('git', args, dir: dir, timeout: timeout);
  if (result.exitCode != 0) {
    throw CommandException(step ?? 'git ${args.first}', result.stderr);
  }
  return result.stdout;
}

/// Runs [executable]; if it outlives [timeout], kills it and reports a
/// failure whose stderr says it timed out.
Future<({int exitCode, String stdout, String stderr})> _run(
  String executable,
  List<String> args, {
  String? dir,
  Duration? timeout,
}) async {
  var process = await Process.start(executable, args,
      workingDirectory: dir, environment: const {'GIT_TERMINAL_PROMPT': '0'});
  var out = process.stdout.transform(utf8.decoder).join();
  var err = process.stderr.transform(utf8.decoder).join();
  var timedOut = false;
  var exitCode = await (timeout == null
      ? process.exitCode
      : process.exitCode.timeout(timeout, onTimeout: () {
          timedOut = true;
          process.kill(ProcessSignal.sigkill);
          return exitFailure;
        }));
  if (timedOut) {
    // Children (e.g. git under gh) may keep the pipes open; don't wait.
    return (
      exitCode: exitCode,
      stdout: '',
      stderr: 'timed out after ${timeout!.inSeconds} s',
    );
  }
  return (exitCode: exitCode, stdout: await out, stderr: (await err).trim());
}
