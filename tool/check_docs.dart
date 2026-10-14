/// Checks this repository's documentation conventions (see AGENTS.md):
/// skill manifests, README coverage, design-doc front matter, decision logs,
/// relative links, CLI drift against `references/formats.md`, docs freshness
/// against a base ref, and an optional local privacy denylist.
///
/// Usage: dart tool/check_docs.dart [--base <ref>] [--skill <name>]
library;

import 'dart:convert';
import 'dart:io';

const usage = '''
Checks the documentation conventions described in AGENTS.md.
Run from the repository root.

Usage: dart tool/check_docs.dart [--base <ref>] [--skill <name>]

Options:
  --base <ref>    Git ref to diff against for the freshness check
                  (default: origin/main, if it exists).
  --skill <name>  Only check this skill (root docs are still checked).
  -h, --help      Show this help.

Exit codes: 0 clean (warnings allowed), 1 failures, 2 bad arguments.
''';

const denylistPath = '.docs-denylist';
const docFrontMatterKeys = ['audience', 'purpose', 'kept-current-by'];

final decisionHeading = RegExp(r'^(#{2,4}) (D\d+)\b');
final anyHeading = RegExp(r'^(#{1,6})\s');
final statusLine = RegExp(r'^\s*(?:[-*]\s+)?[*_]*Status[*_]*:[*_]*\s*(.*)$');
final validStatus = RegExp(
  r'^(accepted|withdrawn|superseded by (D\d+))\b',
  caseSensitive: false,
);
final decisionMention = RegExp(r'\bD\d+\b');
final markdownLink = RegExp(
  r'!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)',
);
final ignoredScheme = RegExp(r'^(https?|mailto):', caseSensitive: false);
final longOption = RegExp(r'(?<![\w-])--([a-z][a-z0-9]*(?:-[a-z0-9]+)*)');
final inlineCode = RegExp(r'`[^`\n]*`');
final readmeSkillRef = RegExp(r'(?<![\w-])skills/([\w-]+)');

class Options {
  String? base;
  String? skill;
  bool help = false;
}

enum Level { error, warning, note }

class Finding {
  final Level level;
  final String message;

  Finding(this.level, this.message);

  @override
  String toString() => switch (level) {
        Level.error => '- ERROR: $message',
        Level.warning => '- WARNING: $message',
        Level.note => '- note: $message',
      };
}

/// Findings grouped by check, printed in the order the checks ran.
class Report {
  final _sections = <String, List<Finding>>{};
  var _current = '';

  void start(String section) {
    _current = section;
    _sections[section] = [];
  }

  void error(String message) => _add(Level.error, message);
  void warning(String message) => _add(Level.warning, message);
  void note(String message) => _add(Level.note, message);

  void _add(Level level, String message) =>
      _sections[_current]!.add(Finding(level, message));

  int count(Level level) => _sections.values
      .expand((findings) => findings)
      .where((finding) => finding.level == level)
      .length;

  void printTo(StringSink out) {
    out.writeln('# Doc checks');
    for (var MapEntry(key: section, value: findings) in _sections.entries) {
      out
        ..writeln()
        ..writeln('## $section');
      var problems = findings.where((f) => f.level != Level.note);
      if (problems.isEmpty) out.writeln('- ok');
      findings.forEach(out.writeln);
    }
    var errors = count(Level.error);
    var warnings = count(Level.warning);
    out
      ..writeln()
      ..writeln(
        errors == 0
            ? 'PASSED ($warnings warning(s)).'
            : 'FAILED: $errors error(s), $warnings warning(s).',
      );
  }
}

Future<void> main(List<String> args) async {
  Options options;
  try {
    options = parseArgs(args);
  } on FormatException catch (e) {
    stderr
      ..writeln('Error: ${e.message}')
      ..writeln()
      ..write(usage);
    exit(2);
  }
  if (options.help) {
    stdout.write(usage);
    return;
  }
  if (!Directory('skills').existsSync()) {
    stderr
        .writeln('Error: no skills/ directory; run from the repository root.');
    exit(2);
  }
  var allSkills = listSkills();
  var skill = options.skill;
  if (skill != null && !allSkills.contains(skill)) {
    stderr.writeln('Error: no skill named "$skill" under skills/.');
    exit(2);
  }
  var skills = skill == null ? allSkills : [skill];
  var report = Report();
  await runChecks(report, skills, options);
  report.printTo(stdout);
  exitCode = report.count(Level.error) > 0 ? 1 : 0;
}

Options parseArgs(List<String> args) {
  var options = Options();
  for (var i = 0; i < args.length; i++) {
    var arg = args[i];
    String value() {
      if (i + 1 >= args.length) throw FormatException('$arg needs a value.');
      return args[++i];
    }

    switch (arg) {
      case '-h' || '--help':
        options.help = true;
      case '--base':
        options.base = value();
      case '--skill':
        options.skill = value();
      case _ when arg.startsWith('--base='):
        options.base = arg.substring('--base='.length);
      case _ when arg.startsWith('--skill='):
        options.skill = arg.substring('--skill='.length);
      default:
        throw FormatException('Unknown argument: $arg');
    }
  }
  return options;
}

Future<void> runChecks(
  Report report,
  List<String> skills,
  Options options,
) async {
  var docs = [...rootDocs(), for (var skill in skills) ...skillDocs(skill)];
  report.start('Skill manifests');
  for (var skill in skills) {
    checkManifest(report, skill);
  }
  report.start('README coverage');
  checkReadme(report, skills);
  report.start('Design-doc front matter');
  for (var skill in skills) {
    checkDocFrontMatter(report, skill);
  }
  report.start('Decision logs');
  for (var skill in skills) {
    checkDecisions(report, skill);
  }
  report.start('Links');
  checkLinks(report, docs);
  report.start('CLI drift');
  for (var skill in skills) {
    await checkCliDrift(report, skill);
  }
  report.start('Freshness');
  await checkFreshness(report, skills, options.base);
  report.start('Privacy');
  await checkPrivacy(report, docs);
}

// --- File helpers -----------------------------------------------------------

String normalize(String path) =>
    path.replaceAll(r'\', '/').replaceFirst(RegExp(r'^\./'), '');

String baseName(String path) => normalize(path).split('/').last;

List<String> listSkills() => Directory('skills')
    .listSync()
    .whereType<Directory>()
    .map((dir) => baseName(dir.path))
    .where((name) => !name.startsWith('.'))
    .toList()
  ..sort();

List<String> markdownUnder(String dir) {
  if (!Directory(dir).existsSync()) return [];
  return Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => normalize(file.path))
      .where((path) => path.endsWith('.md'))
      .toList()
    ..sort();
}

/// README.md, AGENTS.md, and tool/**/*.md.
List<String> rootDocs() => [
      for (var name in ['README.md', 'AGENTS.md'])
        if (File(name).existsSync()) name,
      ...markdownUnder('tool'),
    ];

List<String> skillDocs(String skill) => markdownUnder('skills/$skill');

/// Replaces fenced code blocks and inline code spans with blanks, keeping
/// line numbers stable.
List<String> proseLines(String text) {
  var inFence = false;
  var lines = <String>[];
  for (var line in const LineSplitter().convert(text)) {
    var isFence = line.trimLeft().startsWith(RegExp('```|~~~'));
    if (isFence) inFence = !inFence;
    lines.add(isFence || inFence ? '' : line.replaceAll(inlineCode, ''));
  }
  return lines;
}

/// Top-level `key: value` pairs from a leading `---` block, or null if absent.
/// Indented continuation lines are appended to the previous value.
Map<String, String>? frontMatter(String text) {
  var lines = const LineSplitter().convert(text);
  if (lines.isEmpty || lines.first.trim() != '---') return null;
  var end = lines.indexWhere((line) => line.trim() == '---', 1);
  if (end < 0) return null;
  var fields = <String, String>{};
  String? key;
  for (var line in lines.sublist(1, end)) {
    var match = RegExp(r'^([A-Za-z][\w-]*):\s*(.*)$').firstMatch(line);
    if (match != null) {
      key = match[1]!;
      fields[key] = scalar(match[2]!);
    } else if (key != null && line.startsWith(RegExp(r'\s'))) {
      fields[key] = '${fields[key]} ${line.trim()}'.trim();
    }
  }
  return fields;
}

String scalar(String raw) {
  var value = raw.trim();
  if (RegExp(r'^[>|][-+]?$').hasMatch(value)) return '';
  if (value.length >= 2 &&
      (value.startsWith('"') && value.endsWith('"') ||
          value.startsWith("'") && value.endsWith("'"))) {
    return value.substring(1, value.length - 1).trim();
  }
  return value;
}

// --- Skill manifests and README ---------------------------------------------

void checkManifest(Report report, String skill) {
  var path = 'skills/$skill/SKILL.md';
  var file = File(path);
  if (!file.existsSync()) {
    report.error('$path is missing.');
    return;
  }
  var fields = frontMatter(file.readAsStringSync());
  if (fields == null) {
    report.error('$path has no YAML front matter.');
    return;
  }
  var name = fields['name'] ?? '';
  if (name != skill) {
    report.error('$path: `name` is "$name", expected "$skill".');
  }
  if ((fields['description'] ?? '').isEmpty) {
    report.error('$path: `description` is missing or empty.');
  }
}

/// README links to skill directories are covered by the link check.
void checkReadme(Report report, List<String> skills) {
  var readme = File('README.md');
  if (!readme.existsSync()) {
    report.error('README.md is missing.');
    return;
  }
  var text = readme.readAsStringSync();
  var referenced =
      readmeSkillRef.allMatches(text).map((match) => match[1]!).toSet();
  for (var skill in skills.where((s) => !referenced.contains(s))) {
    report.error('README.md does not reference `skills/$skill`.');
  }
}

// --- Design docs ------------------------------------------------------------

void checkDocFrontMatter(Report report, String skill) {
  var agents = 'skills/$skill/AGENTS.md';
  var paths = [
    if (File(agents).existsSync()) agents,
    ...markdownUnder('skills/$skill/docs'),
  ];
  for (var path in paths) {
    var fields = frontMatter(File(path).readAsStringSync());
    if (fields == null) {
      report.error(
          '$path has no front matter (${docFrontMatterKeys.join(', ')}).');
      continue;
    }
    var missing = docFrontMatterKeys.where((k) => (fields[k] ?? '').isEmpty);
    if (missing.isNotEmpty) {
      report.error(
          '$path: front matter missing or empty: ${missing.join(', ')}.');
    }
  }
}

class Decision {
  final String id;
  final int line;
  final int level;
  String? status;

  Decision(this.id, this.line, this.level);
}

/// Decision headings with the first `Status:` line in each one's section.
List<Decision> parseDecisions(String text) {
  var decisions = <Decision>[];
  Decision? open;
  var lines = proseLines(text);
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    var heading = anyHeading.firstMatch(line);
    if (heading != null && open != null && heading[1]!.length <= open.level) {
      open = null;
    }
    var decision = decisionHeading.firstMatch(line);
    if (decision != null) {
      open = Decision(decision[2]!, i + 1, decision[1]!.length);
      decisions.add(open);
      continue;
    }
    var status = statusLine.firstMatch(line);
    if (open != null && open.status == null && status != null) {
      open.status = status[1]!.replaceAll(RegExp(r'[*_]'), '').trim();
    }
  }
  return decisions;
}

void checkDecisions(Report report, String skill) {
  var path = 'skills/$skill/docs/decisions.md';
  var file = File(path);
  if (!file.existsSync()) return;
  var decisions = parseDecisions(file.readAsStringSync());
  var defined = <String>{};
  for (var decision in decisions) {
    if (!defined.add(decision.id)) {
      report.error('$path:${decision.line}: ${decision.id} is defined twice.');
    }
  }
  for (var decision in decisions) {
    checkStatus(report, path, decision, defined);
  }
  for (var doc in skillDocs(skill)) {
    checkMentions(report, doc, defined, path);
  }
  report.note('$path: ${decisions.length} decision(s).');
}

void checkStatus(
  Report report,
  String path,
  Decision decision,
  Set<String> defined,
) {
  var where = '$path:${decision.line}: ${decision.id}';
  var status = decision.status;
  if (status == null) {
    report.error('$where has no `Status:` line.');
    return;
  }
  var match = validStatus.firstMatch(status);
  if (match == null) {
    report.error(
      '$where: status "$status" is not accepted, '
      'superseded by Dnn, or withdrawn.',
    );
    return;
  }
  var successor = match[2];
  if (successor != null && !defined.contains(successor)) {
    report.error('$where is superseded by $successor, which is not defined.');
  } else if (successor == decision.id) {
    report.error('$where is superseded by itself.');
  }
}

void checkMentions(
  Report report,
  String doc,
  Set<String> defined,
  String logPath,
) {
  var lines = proseLines(File(doc).readAsStringSync());
  for (var i = 0; i < lines.length; i++) {
    var unknown = decisionMention
        .allMatches(lines[i])
        .map((match) => match[0]!)
        .where((id) => !defined.contains(id))
        .toSet();
    for (var id in unknown) {
      report.error('$doc:${i + 1}: $id is not defined in $logPath.');
    }
  }
}

// --- Links ------------------------------------------------------------------

void checkLinks(Report report, List<String> docs) {
  var checked = 0;
  for (var doc in docs) {
    var lines = proseLines(File(doc).readAsStringSync());
    for (var i = 0; i < lines.length; i++) {
      for (var match in markdownLink.allMatches(lines[i])) {
        var target = match[1]!;
        if (ignoredScheme.hasMatch(target)) continue;
        checked++;
        if (!linkResolves(doc, target)) {
          report.error('$doc:${i + 1}: broken link `$target`.');
        }
      }
    }
  }
  report.note('${docs.length} file(s), $checked relative link(s).');
}

bool linkResolves(String doc, String target) {
  var path = target.split('#').first.split('?').first;
  if (path.isEmpty) return true;
  try {
    path = Uri.decodeComponent(path);
  } on ArgumentError {
    return false;
  }
  var dir = doc.contains('/') ? doc.substring(0, doc.lastIndexOf('/')) : '.';
  var resolved = path.startsWith('/') ? '.$path' : '$dir/$path';
  return File(resolved).existsSync() || Directory(resolved).existsSync();
}

// --- CLI drift --------------------------------------------------------------

Set<String> optionsIn(String text) =>
    longOption.allMatches(text).map((match) => match[1]!).toSet()
      ..remove('help');

Future<void> checkCliDrift(Report report, String skill) async {
  var formatsPath = 'skills/$skill/references/formats.md';
  var formats = File(formatsPath);
  if (!formats.existsSync()) return;
  var text = formats.readAsStringSync();
  var documented = optionsIn(text);
  var backticked = optionsIn(
    inlineCode.allMatches(text).map((m) => m[0]).join('\n'),
  );
  var helped = <String>{};
  var allHelpRan = true;
  for (var script in scriptsOf(skill)) {
    var options = await helpOptions(report, script);
    if (options == null) {
      allHelpRan = false;
      continue;
    }
    helped.addAll(options);
    reportUndocumented(report, script, options.difference(documented));
  }
  if (!allHelpRan) {
    report.note('$formatsPath: reverse check skipped (a --help failed).');
    return;
  }
  for (var option in backticked.difference(helped).toList()..sort()) {
    report.error('$formatsPath mentions `--$option`, which no script accepts.');
  }
}

List<String> scriptsOf(String skill) {
  var dir = Directory('skills/$skill/scripts');
  if (!dir.existsSync()) return [];
  return dir
      .listSync()
      .whereType<File>()
      .map((file) => normalize(file.path))
      .where((path) => path.endsWith('.dart'))
      .toList()
    ..sort();
}

/// The long options in `dart <script> --help`, or null (reported) on failure.
Future<Set<String>?> helpOptions(Report report, String script) async {
  var result = await Process.run(Platform.resolvedExecutable, [
    script,
    '--help',
  ]);
  if (result.exitCode != 0) {
    report.error('$script: `--help` exited with ${result.exitCode}.');
    return null;
  }
  return optionsIn('${result.stdout}\n${result.stderr}');
}

void reportUndocumented(Report report, String script, Set<String> missing) {
  if (missing.isEmpty) {
    report.note('$script: all --help options are in formats.md.');
    return;
  }
  var list = (missing.toList()..sort()).map((o) => '`--$o`').join(', ');
  report.error('$script: not in formats.md: $list.');
}

// --- Freshness --------------------------------------------------------------

Future<void> checkFreshness(
  Report report,
  List<String> skills,
  String? base,
) async {
  var withDocs = skills
      .where((skill) => Directory('skills/$skill/docs').existsSync())
      .toList();
  if (withDocs.isEmpty) {
    report.note('No skill has a docs/ directory; skipped.');
    return;
  }
  var ref = base ?? 'origin/main';
  var changed = await changedFiles(ref);
  if (changed == null) {
    report.note('Skipped: git or base ref `$ref` is unavailable.');
    return;
  }
  for (var skill in withDocs) {
    var prefix = 'skills/$skill/';
    var codeChanged = changed.any(
      (p) => p.startsWith('${prefix}scripts/') || p == '${prefix}SKILL.md',
    );
    var docsChanged = changed.any((p) => p.startsWith('${prefix}docs/'));
    if (codeChanged && !docsChanged) {
      report.warning(
        '$skill: scripts/ or SKILL.md changed since `$ref` but docs/ did not.',
      );
    }
  }
  report.note('Compared against `$ref` (${changed.length} changed file(s)).');
}

/// Files changed since the merge base with [ref], including uncommitted and
/// untracked (not ignored) files.
Future<List<String>?> changedFiles(String ref) async {
  try {
    var mergeBase = await Process.run('git', ['merge-base', ref, 'HEAD']);
    if (mergeBase.exitCode != 0) return null;
    var base = (mergeBase.stdout as String).trim();
    var diff = await Process.run('git', ['diff', '--name-only', base]);
    var untracked = await Process.run('git', [
      'ls-files',
      '--others',
      '--exclude-standard',
    ]);
    if (diff.exitCode != 0 || untracked.exitCode != 0) return null;
    return const LineSplitter().convert('${diff.stdout}${untracked.stdout}');
  } on ProcessException {
    return null;
  }
}

// --- Privacy ----------------------------------------------------------------

Future<void> checkPrivacy(Report report, List<String> docs) async {
  var denylist = File(denylistPath);
  if (!denylist.existsSync()) {
    report.note('No $denylistPath; skipped.');
    return;
  }
  if (await isTracked(denylistPath)) {
    report.error('$denylistPath is tracked by git; remove it from the index.');
  }
  var terms = denylistTerms(denylist.readAsLinesSync());
  for (var doc in docs) {
    scanForTerms(report, doc, terms);
  }
  report.note('${terms.length} term(s) checked in ${docs.length} file(s).');
}

/// Denylist line number to whole-word, case-insensitive pattern. Terms are
/// identified by line number so they are not echoed into logs.
Map<int, RegExp> denylistTerms(List<String> lines) => {
      for (var i = 0; i < lines.length; i++)
        if (lines[i].trim() case var term
            when term.isNotEmpty && term[0] != '#')
          i + 1: RegExp(
            '(?<!\\w)${RegExp.escape(term)}(?!\\w)',
            caseSensitive: false,
          ),
    };

void scanForTerms(Report report, String doc, Map<int, RegExp> terms) {
  var lines = const LineSplitter().convert(File(doc).readAsStringSync());
  for (var i = 0; i < lines.length; i++) {
    for (var MapEntry(key: termLine, value: pattern) in terms.entries) {
      if (pattern.hasMatch(lines[i])) {
        report.error(
          '$doc:${i + 1}: matches $denylistPath entry on line $termLine.',
        );
      }
    }
  }
}

Future<bool> isTracked(String path) async {
  try {
    var result = await Process.run('git', [
      'ls-files',
      '--error-unmatch',
      path,
    ]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
