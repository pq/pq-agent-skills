/// Scores a review-tuner run: validates reviewer (and judge) results,
/// measures replay flag rates, judge noise, and bot fidelity, and applies the
/// confidence rubric. Results are per model (never pooled) and per arm
/// (`baseline` / `candidate`); every subcommand validates first and refuses
/// to score partial or invalid results.
///
/// Usage (also printed by `--help` and on a usage error):
///
///     dart score.dart <validate|replay|noise|fidelity|rubric|all>
///         --run <runDir> [--config <path>] [--output-file <file.json>]
///
/// What each subcommand reports, the file formats, and exit codes:
/// `references/formats.md` and `references/rubric.md`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'src/cli.dart';
import 'src/config.dart';
import 'src/corpus.dart';
import 'src/eval.dart';

// Rubric thresholds (see references/rubric.md). Deltas are candidate minus baseline.

/// Evidence High: weighted comments, distinct PRs (plus a maintainer).
const evidenceHighComments = 3;
const evidenceHighPrs = 2;

/// Evidence Medium: weighted comments (or any maintainer comment).
const evidenceMediumComments = 2;

/// Replay High: held-out change in per-run correct rate (plus
/// [consistencyShare] of held-out cases consistent).
const replayHighHeldoutDelta = 0.5;

/// Replay Medium: motivating change in per-run correct rate.
const replayMediumMotivatingDelta = 0.5;

/// A case is consistent when correct in at least this share of its runs;
/// Replay High needs at least this share of held-out cases consistent.
const consistencyShare = 2 / 3;

/// Noise: change in noise + wrong per run per PR on negatives.
const noiseHighDelta = 0.0;
const noiseMediumDelta = 0.33;
const noiseRejectDelta = 1.0;

/// Fidelity: below this share of bot locations reproduced, suggestions that
/// affect the bot drop one level.
const fidelityThreshold = 0.40;

/// A rubric level, lowest first.
enum Level {
  reject('Reject'),
  low('Low'),
  medium('Medium'),
  high('High');

  const Level(this.label);

  final String label;

  /// One level lower, never below [reject].
  Level drop() => values[max(0, index - 1)];

  /// This level, or [cap] if that is lower.
  Level capAt(Level cap) => index > cap.index ? cap : this;

  static Level lowest(Iterable<Level> levels) =>
      levels.reduce((a, b) => a.index <= b.index ? a : b);
}

/// The `check` verdict: the sign of the change in the per-run correct rate.
enum Verdict {
  helps('helps'),
  noEffect('no effect'),
  hurts('hurts');

  const Verdict(this.label);

  final String label;
}

/// Summaries that suggest the reviewer could not read its inputs.
final _unreadable = RegExp(
  r"permission|could not (read|access)|couldn't (read|open)",
  caseSensitive: false,
);

/// Verdicts a judge may give.
const _judgeVerdicts = {'valid', 'noise', 'wrong'};

/// One value per arm role.
typedef Arms<T> = ({T baseline, T candidate});

/// [f] applied to each arm role name.
Arms<T> _perArm<T>(T Function(String role) f) =>
    (baseline: f('baseline'), candidate: f('candidate'));

Map<String, Object?> _armsJson<T>(Arms<T> arms, Object? Function(T) f) =>
    {'baseline': f(arms.baseline), 'candidate': f(arms.candidate)};

/// Runs of one case (or a sum over cases) on one arm: how many were valid,
/// flagged the concern, and had the correct outcome.
typedef Tally = ({int runs, int flagged, int correct});

const Tally _noRuns = (runs: 0, flagged: 0, correct: 0);

Tally _sum(Iterable<Tally> tallies) => tallies.fold(
    _noRuns,
    (a, t) => (
          runs: a.runs + t.runs,
          flagged: a.flagged + t.flagged,
          correct: a.correct + t.correct,
        ));

Arms<Tally> _sumArms(Iterable<Arms<Tally>> tallies) => (
      baseline: _sum(tallies.map((t) => t.baseline)),
      candidate: _sum(tallies.map((t) => t.candidate)),
    );

double? _ratio(int a, int b) => b == 0 ? null : a / b;

/// Per-run correct rate.
double? _rate(Tally t) => _ratio(t.correct, t.runs);

/// Candidate minus baseline per-run correct rate (null without runs).
double? _rateChange(Arms<Tally> t) =>
    switch ((_rate(t.baseline), _rate(t.candidate))) {
      (var b?, var a?) => a - b,
      _ => null,
    };

String _signed(double? v) =>
    v == null ? 'n/a' : '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';

/// Like [_signed], but zero has no sign.
String _change(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(2)}';

String _percent(double share) => '${(100 * share).round()}%';

/// Characters of title + body shown per matched comment.
const _matchExcerptLength = 120;

/// A reviewer comment's severity, location, and the start of its title and
/// body, for listing matches.
Map<String, Object?> _matchJson(Map<String, Object?> k) {
  var text = '${k['title']}: ${k['body']}'.replaceAll(RegExp(r'\s+'), ' ');
  return {
    'severity': k['severity'],
    'path': k['path'],
    if (k['line'] != null) 'line': k['line'],
    'text': text.length <= _matchExcerptLength
        ? text
        : '${text.substring(0, _matchExcerptLength)}…',
  };
}

/// A scored part of the output: JSON for `--output-file` / `score.json`,
/// and markdown for stdout.
typedef Part = ({Map<String, Object?> json, String markdown});

/// Options each subcommand accepts.
const _commandOptions = {
  'validate': {'run', 'output-file'},
  'replay': {'run', 'output-file'},
  'noise': {'run', 'output-file'},
  'fidelity': {'run', 'config', 'output-file'},
  'rubric': {'run', 'config', 'output-file'},
  'all': {'run', 'config', 'output-file'},
};

const usage = '''
Usage:
  dart score.dart <validate|replay|noise|fidelity|rubric|all>
      --run <runDir> [--config <path>] [--output-file <file.json>]''';

Future<void> main(List<String> argv) =>
    guarded(usage, argv, () async => score(argv));

void score(List<String> argv) {
  var command = argv.firstOrNull ?? '';
  var allowed = _commandOptions[command] ??
      usageError('Unknown or missing command "$command".');
  var args = parseArgs(argv.sublist(1), options: allowed);
  if (args.positional.isNotEmpty) usageError('Unexpected arguments.');
  var options = args.options;
  var runDir = absPath(options['run'] ?? usageError('Missing --run.'));
  var s = Scorer.load(runDir);
  // Never score partial or malformed inputs.
  var validation = s.validate();
  var validated = (json: validation.toJson(), markdown: validation.markdown);
  var parts = validation.ok
      ? s.sections(command, configPath: options['config'], validated: validated)
      : {'validate': validated};
  var json = parts.length == 1
      ? parts.values.single.json
      : {for (var MapEntry(:key, :value) in parts.entries) key: value.json};
  if (command == 'all' && validation.ok && s.problems.isEmpty) {
    writeJson('$runDir/score.json', json);
  }
  stdout.write(parts.values.map((p) => p.markdown).join('\n'));
  if (options['output-file'] case var path?) writeJson(path, json);
  if (s.problems.isNotEmpty) {
    stderr.writeln('Problems:\n${s.problems.join('\n')}');
    exit(exitFailure);
  }
}

/// One reviewer task from `tasks.json`, with its arm unblinded to its
/// [role] (`baseline` or `candidate`).
typedef ReviewTask = ({
  String id,
  String caseId,
  String role,
  String model,
  int run,
  String output,
});

final class Scorer {
  Scorer._({
    required this.runDir,
    required this.evalDir,
    required this.eval,
    required this.mode,
    required this.armNames,
    required this.tasks,
  }) : _kept = {for (var t in tasks) t.id: _keptComments(t.output)};

  /// Reads `<runDir>/tasks.json` and the eval it names.
  factory Scorer.load(String runDir) {
    var manifest = readJson('$runDir/tasks.json') as Map<String, Object?>;
    var evalDir =
        manifest['evalDir'] as String? ?? Directory(runDir).parent.path;
    var armNames = {
      for (var e in (manifest['arms'] as Map).entries)
        e.key as String: e.value as String,
    };
    return Scorer._(
      runDir: runDir,
      evalDir: evalDir,
      eval: loadEval(evalDir),
      mode: manifest['mode'] as String?,
      armNames: armNames,
      tasks: [
        for (var t in (manifest['tasks'] as List).cast<Map>())
          (
            id: t['id'] as String,
            caseId: t['case'] as String,
            role: armNames[t['arm']] ??
                fail('$runDir/tasks.json: unknown arm "${t['arm']}"'),
            model: t['model'] as String,
            run: t['run'] as int,
            output: t['output'] as String,
          ),
      ],
    );
  }

  final String runDir;
  final String evalDir;
  final Eval eval;

  /// `check` or `evaluate` (from `tasks.json`).
  final String? mode;

  /// Blinded arm (`arm1`/`arm2`) to `baseline`/`candidate`.
  final Map<String, String> armNames;
  final List<ReviewTask> tasks;

  /// Kept comments of each valid result, by task id (null if invalid).
  final Map<String, List<Map<String, Object?>>?> _kept;

  /// Input problems that make the command exit with [exitFailure].
  final problems = <String>[];

  String get primary => eval.primary.label;
  bool get judged => File('$runDir/judge/tasks.json').existsSync();
  String? get corpusPath =>
      eval.corpus == null ? null : '$evalDir/${eval.corpus}';

  static List<Map<String, Object?>>? _keptComments(String output) {
    Object? json;
    try {
      json = jsonDecode(File(output).readAsStringSync());
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
    if (_schemaError(json) != null || (json as Map)['inputError'] != null) {
      return null;
    }
    return [
      for (var c in (json['comments'] as List).cast<Map<String, Object?>>())
        if (isKept(c)) c,
    ];
  }

  /// Kept comments of each valid result for [model], [caseId], and [role]
  /// (`baseline`/`candidate`), keyed by run number.
  Map<int, List<Map<String, Object?>>> runs(
          String model, String caseId, String role) =>
      {
        for (var t in tasks)
          if (t.model == model && t.caseId == caseId && t.role == role)
            if (_kept[t.id] case var kept?) t.run: kept,
      };

  /// Models (labels) that have tasks in this run, primary first.
  List<String> get models => [
        for (var m in eval.models)
          if (tasks.any((t) => t.model == m.label)) m.label,
      ];

  /// Runs per arm for [model] in this run's tasks.
  int runCount(String model) =>
      tasks.where((t) => t.model == model).fold(0, (a, t) => max(a, t.run));

  /// The sections [command] reports, by `score.json` key (omitted when not
  /// measured). Only called once validation passed, as [validated].
  Map<String, Part> sections(String command,
      {required String? configPath, required Part validated}) {
    Part replayPart(Replay r) => (json: r.toJson(), markdown: r.markdown);
    Part noisePart(Noise n) => (json: n.toJson(), markdown: n.markdown);
    Part fidelityPart(Fidelity f) =>
        (json: fidelityJson(f), markdown: renderFidelity(f));
    switch (command) {
      case 'replay':
        return {'replay': replayPart(replay())};
      case 'noise':
        return {'noise': noisePart(noise())};
      case 'fidelity':
        return {
          'fidelity': fidelityPart(configuredFidelity(configPath) ??
              fail('$evalDir/eval.json sets no corpus.')),
        };
      case 'rubric' || 'all':
        var replayed = replay();
        var judgedNoise = judged ? noise() : null;
        var botFidelity = configuredFidelity(configPath);
        var scored = rubric(replayed, judgedNoise, botFidelity);
        var rubricPart = (json: scored.toJson(), markdown: scored.markdown);
        if (command == 'rubric') return {'rubric': rubricPart};
        return {
          'validate': validated,
          'replay': replayPart(replayed),
          if (judgedNoise case var n?) 'noise': noisePart(n),
          if (botFidelity case var f?) 'fidelity': fidelityPart(f),
          'rubric': rubricPart,
        };
      default:
        return {'validate': validated};
    }
  }

  /// Fidelity against the configured reviewer bot's real comments, or null
  /// if `eval.json` sets no corpus.
  Fidelity? configuredFidelity(String? configPath) {
    if (corpusPath case var corpus?) {
      var repo = loadConfig(path: configPath).repo(eval.repo) ??
          fail('$evalDir/eval.json: bad repo "${eval.repo}"');
      return fidelity(corpus, repo.bot);
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // validate

  Validation validate() {
    var missing = <String>[], unparsable = <String>[], warnings = <String>[];
    var invalid = <String, String>{}, inputErrors = <String, String>{};
    for (var t in tasks) {
      var file = File(t.output);
      if (!file.existsSync()) {
        missing.add(t.id);
        continue;
      }
      Object? json;
      try {
        json = jsonDecode(file.readAsStringSync());
      } on FormatException {
        unparsable.add(t.id);
        continue;
      }
      if (_schemaError(json) case var error?) {
        invalid[t.id] = error;
      } else if ((json as Map)['inputError'] case String reason) {
        inputErrors[t.id] = reason;
      } else if (_unreadable.hasMatch(json['summary'] as String)) {
        warnings.add(t.id);
      }
    }
    var v = Validation(
      tasks: tasks.length,
      missing: missing,
      unparsable: unparsable,
      invalid: invalid,
      inputErrors: inputErrors,
      warnings: warnings,
      judgeErrors: judged ? _judgeErrors() : null,
    );
    if (!v.resultsOk) {
      problems.add('Some results are missing or invalid; rerun them.');
    }
    if (v.judgeErrors?.isNotEmpty ?? false) {
      problems.add('Some judge outputs are missing or invalid; rerun them.');
    }
    return v;
  }

  /// Problems with each judge task's output, by task id.
  Map<String, String> _judgeErrors() {
    var manifest = readJson('$runDir/judge/tasks.json') as Map;
    return {
      for (var t in (manifest['tasks'] as List).cast<Map>())
        if (_verdictsError(t['case'] as String, t['output'] as String)
            case var error?)
          t['id'] as String: error,
    };
  }

  String? _verdictsError(String caseId, String output) {
    Object? findings;
    try {
      findings = jsonDecode(
          File('$runDir/judge/$caseId.findings.json').readAsStringSync());
    } on FileSystemException {
      return 'unreadable findings file';
    } on FormatException {
      return 'unreadable findings file';
    }
    if (findings is! List || findings.any((f) => f is! Map)) {
      return 'findings file is not a list of findings';
    }
    var file = File(output);
    if (!file.existsSync()) return 'missing';
    Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException {
      return 'unparsable';
    }
    if (json is! Map || json['verdicts'] is! List) {
      return 'missing "verdicts" list';
    }
    var expected = {for (var f in findings) (f as Map)['id']};
    var seen = <Object?>{};
    for (var v in json['verdicts'] as List) {
      if (v is! Map) return 'verdict not an object';
      var id = v['id'];
      if (!expected.contains(id)) return 'unknown finding id $id';
      if (!seen.add(id)) return 'finding $id judged more than once';
      if (!_judgeVerdicts.contains(v['verdict'])) {
        return 'bad verdict "${v['verdict']}" for $id';
      }
    }
    var unjudged = expected.difference(seen);
    if (unjudged.isNotEmpty) return 'unjudged: ${unjudged.join(', ')}';
    return null;
  }

  static String? _schemaError(Object? json) {
    if (json is! Map) return 'not an object';
    if (json['inputError'] != null) {
      return json['inputError'] is String ? null : 'inputError not a string';
    }
    if (json['summary'] is! String) return 'missing summary';
    if (json['comments'] is! List) return 'missing comments';
    for (var c in json['comments'] as List) {
      if (c is! Map) return 'comment not an object';
      if (c['path'] is! String) return 'comment without path';
      if (c['line'] != null && c['line'] is! int) return 'non-integer line';
      if (!severities.contains(c['severity'])) {
        return 'bad severity "${c['severity']}"';
      }
      if (c['title'] is! String || c['body'] is! String) {
        return 'comment without title or body';
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // replay

  Replay replay() => Replay([for (var m in models) _replayModel(m)]);

  /// [model]'s valid runs of case [c] on arm [role].
  Tally _tally(String model, EvalCase c, String role) {
    var rs = runs(model, c.id, role).values;
    var runCount = rs.length;
    var flagged =
        rs.where((cs) => cs.any((k) => eval.flags(k, c.group))).length;
    return (
      runs: runCount,
      flagged: flagged,
      correct: c.want == Want.flag ? flagged : runCount - flagged,
    );
  }

  ModelReplay _replayModel(String model) {
    var cases = [
      for (var c in eval.cases)
        (c: c, arms: _perArm((role) => _tally(model, c, role))),
    ];
    var scored = [
      for (var t in cases)
        if (t.c.want != Want.none) t,
    ];
    Arms<Tally> total(Iterable<CaseTally> ts) =>
        _sumArms([for (var t in ts) t.arms]);
    var heldout = [
      for (var t in scored)
        if (t.c.set == CaseSet.heldout) t.arms,
    ];
    int consistent(Tally Function(Arms<Tally>) arm) => heldout
        .where((t) => arm(t).correct >= consistencyShare * arm(t).runs)
        .length;
    var totals = total(scored);
    var rateDelta = _rateChange(totals);
    return (
      model: model,
      runCount: runCount(model),
      cases: cases,
      sets: [
        for (var set in CaseSet.values)
          for (var want in const [Want.noFlag, Want.flag])
            if (scored.where((t) => t.c.set == set && t.c.want == want).toList()
                case var ts when ts.isNotEmpty)
              (set: set, want: want, cases: ts.length, totals: total(ts)),
      ],
      delta: {
        for (var set in CaseSet.values)
          if (_rateChange(total(scored.where((t) => t.c.set == set)))
              case var d?)
            set: d,
      },
      consistent: (
        baseline: consistent((t) => t.baseline),
        candidate: consistent((t) => t.candidate),
      ),
      heldoutCases: heldout.length,
      scoredCases: scored.length,
      totals: totals,
      rateDelta: rateDelta,
      verdict: switch (rateDelta) {
        var d? when d > 0 => Verdict.helps,
        var d? when d < 0 => Verdict.hurts,
        _ => Verdict.noEffect,
      },
      // Losing a want=flag case caps the rubric's Replay row at Low; it
      // doesn't change the verdict.
      lostFlagCases: [
        for (var t in scored)
          if (t.c.want == Want.flag)
            if (_rateChange(t.arms) case var d? when d < 0) t.c.id,
      ],
      matches: [
        for (var c in eval.cases)
          for (var role in const ['baseline', 'candidate'])
            for (var MapEntry(key: run, value: comments)
                in (runs(model, c.id, role).entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key))))
              if (comments.where((k) => eval.flags(k, c.group)).toList()
                  case var flagged when flagged.isNotEmpty)
                (c: c, role: role, run: run, comments: flagged),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // noise

  Noise noise() {
    var judged = _judgedFindings();
    var bad = <(String, CaseSet, String), ({int all, int nonTarget})>{};
    var concern = <String, ({int flags, int wrong})>{};
    for (var f in judged.findings) {
      var target = eval.flags(f.finding, f.c.group);
      if (f.verdict == 'noise' || f.verdict == 'wrong') {
        var key = (f.model, f.c.set, f.role);
        var n = bad[key] ?? (all: 0, nonTarget: 0);
        bad[key] = (all: n.all + 1, nonTarget: n.nonTarget + (target ? 0 : 1));
      }
      if (f.role == 'baseline' && target && f.c.want == Want.noFlag) {
        var n = concern[f.model] ?? (flags: 0, wrong: 0);
        concern[f.model] = (
          flags: n.flags + 1,
          wrong: n.wrong + (f.verdict == 'wrong' ? 1 : 0),
        );
      }
    }

    // Mean bad findings per run per PR of [set] on [role].
    NoiseRate rate(String model, CaseSet set, List<EvalCase> cs, String role) {
      var runCount =
          cs.fold<int>(0, (a, c) => a + runs(model, c.id, role).length);
      var n = bad[(model, set, role)] ?? (all: 0, nonTarget: 0);
      return runCount == 0
          ? (all: 0, nonTarget: 0)
          : (all: n.all / runCount, nonTarget: n.nonTarget / runCount);
    }

    return Noise([
      // A judged model with no bad findings still measured 0.
      for (var model in models.where(judged.models.contains))
        (
          model: model,
          sets: [
            for (var set in CaseSet.values)
              if (judged.cases.where((c) => c.set == set).toList() case var cs
                  when cs.isNotEmpty)
                (
                  set: set,
                  cases: cs.length,
                  rate: _perArm((role) => rate(model, set, cs, role)),
                ),
          ],
          concern: concern[model] ?? (flags: 0, wrong: 0),
        ),
    ]);
  }

  /// Every judged finding with its case, source, and verdict; the cases that
  /// have a findings file; and the models whose findings were judged.
  ({
    List<EvalCase> cases,
    List<JudgedFinding> findings,
    Set<String> models,
  }) _judgedFindings() {
    var dir = '$runDir/judge';
    var mapping =
        (readJson('$dir/tasks.json') as Map)['mapping'] as Map? ?? const {};
    var cases = <EvalCase>[];
    var findings = <JudgedFinding>[];
    for (var c in eval.cases) {
      var findingsFile = File('$dir/${c.id}.findings.json');
      if (!findingsFile.existsSync()) continue;
      cases.add(c);
      var caseFindings = readJson(findingsFile.path) as List;
      var verdictsFile = '$dir/${c.id}.verdicts.json';
      if (caseFindings.isEmpty) continue;
      if (!File(verdictsFile).existsSync()) {
        problems.add('${c.id}: no verdicts');
        continue;
      }
      var verdicts = {
        for (var v in (readJson(verdictsFile) as Map)['verdicts'] as List)
          (v as Map)['id']: v['verdict'] as String,
      };
      for (var f in caseFindings.cast<Map<String, Object?>>()) {
        var id = f['id'];
        switch ((mapping[id], verdicts[id])) {
          case (Map m, String verdict):
            findings.add((
              c: c,
              finding: f,
              model: m['model'] as String,
              role: armNames[m['arm']] ??
                  fail('$dir/tasks.json: unknown arm "${m['arm']}"'),
              verdict: verdict,
            ));
          case (var m, _):
            problems.add('${c.id}: finding $id is '
                '${m == null ? 'not in the mapping' : 'unjudged'}');
        }
      }
    }
    return (
      cases: cases,
      findings: findings,
      models: {for (var m in mapping.values) (m as Map)['model'] as String},
    );
  }

  // ---------------------------------------------------------------------
  // fidelity

  Fidelity fidelity(String corpusPath, String bot) {
    var prs = {for (var pr in readCorpus(corpusPath)) pr.number: pr};
    var motivating = [
      for (var c in eval.cases)
        if (c.set == CaseSet.motivating && !c.synthetic)
          if ((c.pr, c.commit) case (var pr?, var commit?))
            (c: c, pr: pr, commit: commit),
    ];
    // Distinct (case, path) where the bot flagged the concern.
    var locations = <(EvalCase, String)>{};
    var everyFileFlagged = true;
    // Whether any bot comment has a severity or tag the flag rule can use.
    var measurable = false;
    for (var (:c, :pr, :commit) in motivating) {
      var corpusPr = prs[pr];
      if (corpusPr == null) {
        problems.add('${c.id}: PR $pr not in the corpus');
        continue;
      }
      var paths = <String>{};
      for (var k in corpusPr.comments) {
        if (k.author != bot ||
            k.kind != CommentKind.inline ||
            !(k.commitId ?? '').startsWith(commit)) {
          continue;
        }
        measurable |= k.severity != null || eval.concern.tagged(k.body);
        var finding = {'path': k.path, 'body': k.body, 'severity': k.severity};
        if (k.path case var path? when eval.flags(finding, c.group)) {
          paths.add(path);
        }
      }
      locations.addAll([for (var p in paths) (c, p)]);
      var inGroup =
          _diffFiles(c, corpusPr).where((p) => eval.inGroup(p, c.group));
      if (paths.isNotEmpty && !inGroup.every(paths.contains)) {
        everyFileFlagged = false;
      }
    }
    var sorted = locations.toList()
      ..sort((a, b) => '${a.$1.id} ${a.$2}'.compareTo('${b.$1.id} ${b.$2}'));
    return (
      bot: bot,
      measurable: measurable,
      locations: sorted,
      recallOnly: locations.isNotEmpty && everyFileFlagged,
      motivatingCases: motivating.length,
      models: [
        if (sorted.isNotEmpty)
          for (var model in models)
            _modelFidelity(model, sorted, [for (var m in motivating) m.c]),
      ],
    );
  }

  /// How often [model]'s baseline runs reproduced each bot location.
  ModelFidelity _modelFidelity(String model, List<(EvalCase, String)> locations,
      List<EvalCase> motivating) {
    var hits = 0, total = 0;
    var perRun = <int, int>{};
    var perLocation = <String, int>{};
    for (var (c, path) in locations) {
      for (var MapEntry(key: run, value: comments)
          in runs(model, c.id, 'baseline').entries) {
        total++;
        if (comments.any((k) => k['path'] == path && eval.flags(k, c.group))) {
          hits++;
          perRun[run] = (perRun[run] ?? 0) + 1;
          perLocation['${c.id} $path'] =
              (perLocation['${c.id} $path'] ?? 0) + 1;
        }
      }
    }
    var runNumbers = {
      for (var c in motivating) ...runs(model, c.id, 'baseline').keys,
    }.toList()
      ..sort();
    return (
      model: model,
      hits: hits,
      total: total,
      perRun: {for (var r in runNumbers) r: perRun[r] ?? 0},
      perLocation: perLocation,
    );
  }

  /// Files changed by [c]: from the prepared diff if present, else the
  /// corpus PR's final file list.
  List<String> _diffFiles(EvalCase c, PullRequest pr) {
    var diff = File('$runDir/work/cases/${c.id}/diff.patch');
    if (diff.existsSync()) {
      return [
        for (var m in RegExp(r'^diff --git a/\S+ b/(\S+)', multiLine: true)
            .allMatches(diff.readAsStringSync()))
          if (m[1] case var path?) path,
      ];
    }
    return [for (var f in pr.files) f.path];
  }

  // ---------------------------------------------------------------------
  // rubric

  Rubric rubric(Replay replay, Noise? noise, Fidelity? fidelity) {
    var p = replay.models.where((r) => r.model == primary).firstOrNull ??
        fail('No $primary results to score.');
    var evidence = _evidenceRow();
    var replayRow = _replayRow(p);
    var noiseRow = _noiseRow(noise);
    var level = Level.lowest([
      evidence.level,
      replayRow.level,
      if (noiseRow.level case var l?) l,
    ]);
    var fidelityRow = _fidelityRow(fidelity);
    var robustnessRow = _robustnessRow(replay);
    for (var modifier in [fidelityRow, robustnessRow]) {
      if (modifier.drop) level = level.drop();
    }
    return Rubric(
      rows: [
        evidence.row,
        replayRow.row,
        noiseRow.row,
        fidelityRow.row,
        robustnessRow.row,
      ],
      overall: level,
    );
  }

  ({RubricRow row, Level level}) _evidenceRow() {
    var ev = eval.evidence;
    if (ev == null && mode == 'evaluate') {
      problems.add('$evalDir/eval.json has no "evidence": an evaluate run '
          'needs it for the rubric\'s Evidence row.');
    }
    var (:weightedComments, :prs, :reviewers, :maintainer, :contradiction) =
        ev ??
            (
              weightedComments: 0,
              prs: 0,
              reviewers: const <String>[],
              maintainer: false,
              contradiction: false,
            );
    // Evidence never rejects on its own: Low is the floor.
    var level = switch (weightedComments) {
      _ when contradiction && eval.type == ChangeType.fix => Level.high,
      var w
          when w >= evidenceHighComments &&
              prs >= evidenceHighPrs &&
              maintainer =>
        Level.high,
      var w when w >= evidenceMediumComments || maintainer => Level.medium,
      _ => Level.low,
    };
    return (
      row: (
        row: 'Evidence',
        result: '$weightedComments weighted comments across $prs PRs, '
            'reviewers: ${reviewers.isEmpty ? 'none' : reviewers.join(', ')}'
            '${maintainer ? ' (maintainer)' : ''}'
            '${reviewers.length == 1 ? ', single-reviewer' : ''}'
            '${contradiction ? '; deterministic contradiction' : ''}',
        level: level.label,
      ),
      level: level,
    );
  }

  ({RubricRow row, Level level}) _replayRow(ModelReplay p) {
    var dh = p.delta[CaseSet.heldout];
    var dm = p.delta[CaseSet.motivating] ?? 0;
    var consistency = _ratio(p.consistent.candidate, p.heldoutCases);
    var level = switch ((dh, consistency)) {
      _ when p.verdict == Verdict.hurts => Level.reject,
      (var h?, var c?)
          when h >= replayHighHeldoutDelta && c >= consistencyShare =>
        Level.high,
      _ when dm >= replayMediumMotivatingDelta && (dh == null || dh > 0) =>
        Level.medium,
      _ when dm > 0 || (dh ?? 0) > 0 => Level.low,
      _ => Level.reject,
    };
    var lost = p.lostFlagCases;
    if (lost.isNotEmpty) level = level.capAt(Level.low);
    return (
      row: (
        row: 'Replay',
        result: '$primary: held-out delta ${_signed(dh)} '
            '(>= $replayHighHeldoutDelta for High), consistency '
            '${p.consistent.candidate}/${p.heldoutCases} '
            '(>= ${_percent(consistencyShare)}), motivating delta '
            '${_signed(p.delta[CaseSet.motivating])}; check verdict '
            '${p.verdict.label}'
            '${dh == null ? '; motivating only (capped at Medium)' : ''}'
            '${lost.isEmpty ? '' : '; loses want=flag case(s) '
                '${lost.join(', ')} (capped at Low)'}',
        level: level.label,
      ),
      level: level,
    );
  }

  /// The Noise row (primary model, negatives); no level if not measured.
  ({RubricRow row, Level? level}) _noiseRow(Noise? noise) {
    var model = noise?.models.where((m) => m.model == primary).firstOrNull;
    var negatives =
        model?.sets.where((s) => s.set == CaseSet.negative).firstOrNull;
    if (model == null || negatives == null) {
      var result = noise == null ? 'not measured' : 'no judged negatives';
      if (mode == 'evaluate') {
        problems.add('Noise $result for $primary: an evaluate run needs the '
            'blind judge on its negatives (prepare.dart judge, then score).');
      }
      return (
        row: (row: 'Noise', result: result, level: 'not measured'),
        level: null,
      );
    }
    var dn = negatives.rate.candidate.all - negatives.rate.baseline.all;
    var level = switch (dn) {
      <= noiseHighDelta => Level.high,
      <= noiseMediumDelta => Level.medium,
      <= noiseRejectDelta => Level.low,
      _ => Level.reject,
    };
    return (
      row: (
        row: 'Noise',
        result: 'delta noise on negatives ${_signed(dn)} per run per PR '
            '(${negatives.cases} PRs; <= $noiseHighDelta for High); '
            '${model.concern.wrong}/${model.concern.flags} baseline concern '
            'flags on want=no-flag cases judged wrong',
        level: level.label,
      ),
      level: level,
    );
  }

  /// The Fidelity modifier (primary model).
  ({RubricRow row, bool drop}) _fidelityRow(Fidelity? fidelity) {
    var model = fidelity?.models.where((m) => m.model == primary).firstOrNull;
    if (fidelity == null || model == null || model.total == 0) {
      var why = fidelity?.measurable == false
          ? 'not measurable for this bot'
          : 'not measured';
      return (
        row: (row: 'Fidelity', result: why, level: 'no modifier'),
        drop: false,
      );
    }
    var rate = model.hits / model.total;
    var drop = rate < fidelityThreshold && eval.affects != Affects.local;
    return (
      row: (
        row: 'Fidelity',
        result: '$primary reproduced ${_percent(rate)} of bot locations '
            '(threshold ${_percent(fidelityThreshold)})'
            '${fidelity.recallOnly ? '; recall only' : ''}',
        level: drop ? 'drop one level' : 'no modifier',
      ),
      drop: drop,
    );
  }

  /// The Robustness modifier (non-primary models).
  ({RubricRow row, bool drop}) _robustnessRow(Replay replay) {
    var others = replay.models.where((r) => r.model != primary).toList();
    if (others.isEmpty) {
      return (
        row: (row: 'Robustness', result: 'not run', level: 'no modifier'),
        drop: false,
      );
    }
    var drop = others.any((o) => o.verdict != Verdict.helps);
    return (
      row: (
        row: 'Robustness',
        result:
            [for (var o in others) '${o.model}: ${o.verdict.label}'].join(', '),
        level: drop ? 'drop one level' : 'no modifier',
      ),
      drop: drop,
    );
  }
}

// -------------------------------------------------------------------------
// Results: each computed by [Scorer], rendered as JSON and markdown.

final class Validation {
  Validation({
    required this.tasks,
    required this.missing,
    required this.unparsable,
    required this.invalid,
    required this.inputErrors,
    required this.warnings,
    required this.judgeErrors,
  });

  final int tasks;
  final List<String> missing;
  final List<String> unparsable;
  final Map<String, String> invalid;
  final Map<String, String> inputErrors;

  /// Results whose summary suggests unreadable inputs (not a failure).
  final List<String> warnings;

  /// Judge output problems by task id; null if the run has no judge tasks.
  final Map<String, String>? judgeErrors;

  bool get resultsOk =>
      missing.isEmpty &&
      unparsable.isEmpty &&
      invalid.isEmpty &&
      inputErrors.isEmpty;

  bool get ok => resultsOk && (judgeErrors?.isEmpty ?? true);

  Map<String, Object?> toJson() => {
        'ok': ok,
        'tasks': tasks,
        'missing': missing,
        'unparsable': unparsable,
        'invalid': invalid,
        'inputError': inputErrors,
        'warnings': warnings,
        if (judgeErrors case var errors?) 'judge': errors,
      };

  String get markdown {
    var bad = missing.length +
        unparsable.length +
        invalid.length +
        inputErrors.length;
    var md = StringBuffer('## Validate\n\n')
      ..writeln('${tasks - bad}/$tasks results valid.');
    void list(String label, Iterable<String> lines) {
      if (lines.isEmpty) return;
      md.writeln('\n$label:');
      for (var line in lines) {
        md.writeln('- $line');
      }
    }

    List<String> entries(Map<String, String> m) =>
        [for (var e in m.entries) '${e.key}: ${e.value}'];

    list('Missing', missing);
    list('Unparsable', unparsable);
    list('Invalid', entries(invalid));
    list('inputError', entries(inputErrors));
    list('Warning: summary mentions unreadable inputs (check, not a failure)',
        warnings);
    if (judgeErrors case var errors?) {
      md.writeln('\nJudge outputs: ${errors.isEmpty ? 'all valid' : ''
          '${errors.length} missing or invalid'}.');
      list('Judge', entries(errors));
    }
    return md.toString();
  }
}

/// One case's tallies per arm.
typedef CaseTally = ({EvalCase c, Arms<Tally> arms});

/// Replay totals for one case set and expected outcome.
typedef SetTotals = ({CaseSet set, Want want, int cases, Arms<Tally> totals});

/// One model's replay results.
typedef ModelReplay = ({
  String model,
  int runCount,

  /// Every case, in `eval.json` order, with its tallies per arm.
  List<CaseTally> cases,
  List<SetTotals> sets,

  /// Change in per-run correct rate per set (scored cases).
  Map<CaseSet, double> delta,

  /// Scored held-out cases correct in at least [consistencyShare] of runs.
  Arms<int> consistent,
  int heldoutCases,
  int scoredCases,

  /// Over all scored cases.
  Arms<Tally> totals,
  double? rateDelta,
  Verdict verdict,

  /// `want: flag` cases whose candidate correct rate is below the baseline's.
  List<String> lostFlagCases,

  /// The comments that flagged the concern, per case, arm, and run (runs
  /// that flag it only).
  List<RunMatches> matches,
});

/// The comments of one run that flag the concern.
typedef RunMatches = ({
  EvalCase c,
  String role,
  int run,
  List<Map<String, Object?>> comments,
});

Map<String, Object?> replayJson(ModelReplay r) => {
      'cases': {
        for (var (:c, :arms) in r.cases)
          c.id: _armsJson(arms, (t) => {'runs': t.runs, 'flagged': t.flagged}),
      },
      'sets': {
        for (var s in r.sets)
          '${s.set.name}/${s.want.json}': {
            'cases': s.cases,
            ..._armsJson(
                s.totals,
                (t) => {
                      'flagged': t.flagged,
                      'correct': t.correct,
                      'runs': t.runs,
                    }),
          },
      },
      'delta': {for (var e in r.delta.entries) e.key.name: e.value},
      'consistency': {
        ..._armsJson(r.consistent, (n) => n),
        'cases': r.heldoutCases,
      },
      'verdict': {
        'verdict': r.verdict.label,
        'baselineCorrect': r.totals.baseline.correct,
        'baselineRuns': r.totals.baseline.runs,
        'candidateCorrect': r.totals.candidate.correct,
        'candidateRuns': r.totals.candidate.runs,
        'rateDelta': r.rateDelta,
        'lostFlagCases': r.lostFlagCases,
      },
      'matches': [
        for (var m in r.matches)
          {
            'case': m.c.id,
            'arm': m.role,
            'run': m.run,
            'comments': [for (var k in m.comments) _matchJson(k)],
          },
      ],
    };

String renderReplay(ModelReplay r) {
  String frac(Tally t) => '${t.flagged}/${t.runs}';
  var md = StringBuffer()
    ..writeln('\n### ${r.model} (${r.runCount} run(s) per arm)\n')
    ..writeln('Runs that flag the concern (in the case\'s path group):\n')
    ..writeln('| Case | Set | Group | Want | Baseline | Candidate |')
    ..writeln('|---|---|---|---|---|---|');
  for (var (:c, :arms) in r.cases) {
    md.writeln('| ${c.id} | ${c.set.name} | ${c.group} | ${c.want.json} '
        '| ${frac(arms.baseline)} | ${frac(arms.candidate)} |');
  }
  md.writeln('\n| Set | Want | Cases | Measure | Baseline | Candidate |\n'
      '|---|---|---|---|---|---|');
  for (var (:set, :want, :cases, :totals) in r.sets) {
    md.writeln('| ${set.name} | ${want.json} | $cases '
        '| ${want == Want.flag ? 'recall' : 'false flags'} '
        '| ${frac(totals.baseline)} runs | ${frac(totals.candidate)} runs |');
  }
  if (r.heldoutCases > 0) {
    md.writeln('\nHeld-out consistency (correct in >= '
        '${_percent(consistencyShare)} of ${r.runCount} run(s)): baseline '
        '${r.consistent.baseline}/${r.heldoutCases}, candidate '
        '${r.consistent.candidate}/${r.heldoutCases}.');
  }
  var lost = r.lostFlagCases;
  md.writeln('\n**Check verdict: ${r.verdict.label}.** Correct runs over '
      '${r.scoredCases} scored cases: baseline '
      '${r.totals.baseline.correct}/${r.totals.baseline.runs}, candidate '
      '${r.totals.candidate.correct}/${r.totals.candidate.runs} '
      '(rate delta ${_signed(r.rateDelta)})'
      '${lost.isEmpty ? '' : '; loses want=flag case(s) '
          '${lost.join(', ')} (caps Replay at Low)'}.');
  if (r.matches.isNotEmpty) md.writeln('\nMatched comments:\n');
  for (var m in r.matches) {
    for (var k in m.comments.map(_matchJson)) {
      var line = k['line'] == null ? '' : ':${k['line']}';
      md.writeln('- ${m.c.id} ${m.role} r${m.run}: [${k['severity']}] '
          '`${k['path']}$line` ${k['text']}');
    }
  }
  return md.toString();
}

final class Replay {
  Replay(this.models);

  final List<ModelReplay> models;

  Map<String, Object?> toJson() =>
      {for (var m in models) m.model: replayJson(m)};

  String get markdown =>
      ['## Replay\n', for (var m in models) renderReplay(m)].join();
}

/// A judged finding: its case, the finding as the judge saw it, its source
/// model and arm role, and the judge's verdict.
typedef JudgedFinding = ({
  EvalCase c,
  Map<String, Object?> finding,
  String model,
  String role,
  String verdict,
});

/// Mean findings judged `noise` or `wrong` per run per PR: all of them, and
/// those that don't flag the concern.
typedef NoiseRate = ({double all, double nonTarget});

typedef ModelNoise = ({
  String model,
  List<({CaseSet set, int cases, Arms<NoiseRate> rate})> sets,

  /// Baseline findings that flag the concern on `want: no-flag` cases, and
  /// how many of them the judge rated `wrong`.
  ({int flags, int wrong}) concern,
});

final class Noise {
  Noise(this.models);

  final List<ModelNoise> models;

  Map<String, Object?> toJson() => {
        for (var m in models)
          m.model: {
            'sets': {
              for (var s in m.sets)
                s.set.name: {
                  ..._armsJson(
                      s.rate, (r) => {'all': r.all, 'nonTarget': r.nonTarget}),
                  'cases': s.cases,
                },
            },
            'baselineConcernFlags': {
              'flags': m.concern.flags,
              'wrong': m.concern.wrong,
            },
          },
      };

  String get markdown {
    var md = StringBuffer('## Noise (blind judge)\n');
    for (var m in models) {
      md
        ..writeln('\n### ${m.model}: noise + wrong per run per PR\n')
        ..writeln('| Set | PRs | Baseline | Candidate | Delta '
            '| Non-target baseline | Non-target candidate | Delta |')
        ..writeln('|---|---|---|---|---|---|---|---|');
      for (var (:set, :cases, rate: (:baseline, :candidate)) in m.sets) {
        String f(double v) => v.toStringAsFixed(2);
        md.writeln('| ${set.name} | $cases | ${f(baseline.all)} '
            '| ${f(candidate.all)} | ${_change(candidate.all - baseline.all)} '
            '| ${f(baseline.nonTarget)} | ${f(candidate.nonTarget)} '
            '| ${_change(candidate.nonTarget - baseline.nonTarget)} |');
      }
      md.writeln('\nBaseline findings that flag the concern on want=no-flag '
          'cases judged wrong: ${m.concern.wrong} of ${m.concern.flags}.');
    }
    md.writeln('\nNon-target excludes findings that flag the concern.');
    return md.toString();
  }
}

/// How often one model's baseline runs reproduced the bot's locations.
typedef ModelFidelity = ({
  String model,
  int hits,
  int total,

  /// Locations reproduced, by run number (every run, including zeros).
  Map<int, int> perRun,
  Map<String, int> perLocation,
});

/// Bot fidelity: where the bot flagged the concern, and how often each
/// model's baseline runs reproduced it.
typedef Fidelity = ({
  String bot,

  /// False when no bot comment has a severity or tag the flag rule can use.
  bool measurable,

  /// Distinct (case, path) where the bot flagged the concern, sorted.
  List<(EvalCase, String)> locations,

  /// The bot flagged every in-group file, so only recall is measured.
  bool recallOnly,
  int motivatingCases,

  /// Empty when there are no `locations`.
  List<ModelFidelity> models,
});

Map<String, Object?> fidelityJson(Fidelity f) => !f.measurable
    ? {'bot': f.bot, 'measurable': false}
    : {
        'bot': f.bot,
        'locations': [
          for (var (c, p) in f.locations) {'case': c.id, 'path': p},
        ],
        'recallOnly': f.recallOnly,
        if (f.locations.isNotEmpty)
          'models': {
            for (var m in f.models)
              m.model: {
                'reproduced': m.hits,
                'locationRuns': m.total,
                'rate': _ratio(m.hits, m.total),
                'perRun': {
                  for (var MapEntry(:key, :value) in m.perRun.entries)
                    '$key': value,
                },
                'perLocation': m.perLocation,
              },
          },
      };

String renderFidelity(Fidelity f) {
  var md = StringBuffer('## Bot fidelity (baseline arm vs `${f.bot}`)\n\n');
  if (!f.measurable) {
    md.writeln('Fidelity not measurable for this bot: none of its comments '
        'on the motivating cases has a recognizable severity or tag.');
    return md.toString();
  }
  var locations = f.locations;
  if (locations.isEmpty) {
    md.writeln('The bot posted no comments flagging the concern on '
        'motivating cases at the reviewed commits; fidelity not measured.');
    return md.toString();
  }
  md
    ..writeln('${locations.length} bot locations (distinct case + file) '
        'across ${f.motivatingCases} motivating PRs.\n')
    ..writeln('| Model | Location-runs reproduced | Per run |')
    ..writeln('|---|---|---|');
  for (var m in f.models) {
    var share = m.total == 0 ? '' : ' (${_percent(m.hits / m.total)})';
    var perRun = [for (var n in m.perRun.values) '$n/${locations.length}'];
    md.writeln('| ${m.model} | ${m.hits}/${m.total}$share '
        '| ${perRun.join(', ')} |');
  }
  if (f.recallOnly) {
    md.writeln('\nThe bot flagged every in-group file of these diffs, so '
        'this measures recall only: a reviewer that flags everything '
        'scores 100%.');
  }
  return md.toString();
}

/// One rubric row: its name, the measured result, and its level (or
/// modifier) label.
typedef RubricRow = ({String row, String result, String level});

final class Rubric {
  Rubric({required this.rows, required this.overall});

  final List<RubricRow> rows;
  final Level overall;

  Map<String, Object?> toJson() => {
        'rows': [
          for (var r in rows)
            {'row': r.row, 'result': r.result, 'level': r.level},
        ],
        'overall': overall.label,
      };

  String get markdown {
    var md =
        StringBuffer('## Rubric\n\n| Row | Result | Level |\n|---|---|---|\n');
    for (var r in rows) {
      md.writeln('| ${r.row} | ${r.result} | ${r.level} |');
    }
    md.writeln('\n**Overall: ${overall.label}.** Small samples: a structured '
        'judgment, not a statistical test.');
    return md.toString();
  }
}
