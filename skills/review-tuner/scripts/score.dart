/// Scores a review-tuner run: validates reviewer results, measures replay
/// flag rates, judge noise, and bot fidelity, and applies the confidence
/// rubric. Every comment is classified with the single flag rule
/// (`Eval.flags`, see `references/formats.md`). Results are reported per
/// model (never pooled) and per arm as `baseline` / `candidate`.
///
/// Usage (the eval dir defaults to the run dir's parent):
///
///     dart run score.dart validate --run <runDir> [--eval <evalDir>]
///     dart run score.dart replay   --run <runDir> [--eval <evalDir>]
///     dart run score.dart noise    --run <runDir> [--eval <evalDir>]
///     dart run score.dart fidelity --run <runDir> --corpus <file.jsonl>
///         [--bot <login>] [--config <path>]
///     dart run score.dart rubric   --run <runDir> [--config <path>]
///     dart run score.dart all      --run <runDir> [--config <path>]
///
/// * `validate`: every task has a result file that parses and matches the
///   result schema; lists missing, unparsable, invalid, and `inputError`
///   results by task id (to rerun), and warns about summaries that mention
///   unreadable inputs.
/// * `replay`: per model, case, and arm, the fraction of runs that flag the
///   concern; per-set summaries, consistency, and the check verdict
///   (`helps`, `no effect`, `hurts`).
/// * `noise`: joins `judge/<case>.verdicts.json` with the `judge/tasks.json`
///   mapping; mean noise + wrong findings per run per PR, overall and
///   excluding findings that flag the concern (non-target).
/// * `fidelity`: how many of the bot's real flagging comments on motivating
///   cases (distinct case + path) the baseline arm reproduces.
/// * `rubric`: the Evidence / Replay / Noise rows, fidelity and robustness
///   modifiers, and an overall High / Medium / Low / Reject level.
/// * `all`: all of the above (noise if judge files exist, fidelity if
///   `eval.json` sets `corpus`); writes `<runDir>/score.json`.
///
/// Markdown goes to stdout; `--output-file <path>` also writes JSON.
///
/// Exits 0 on success, 1 for missing or invalid inputs (including results
/// that fail validation), and 2 for invalid arguments.
library;

import 'dart:convert';
import 'dart:io';

import 'src/config.dart';
import 'src/eval.dart';

// Rubric thresholds (spec Phase 5, v0). Deltas are candidate minus baseline.

/// Evidence High: weighted comments, distinct PRs (plus a maintainer).
const evidenceHighComments = 3;
const evidenceHighPrs = 2;

/// Evidence Medium: weighted comments (or any maintainer comment).
const evidenceMediumComments = 2;

/// Replay High: held-out change in per-run correct rate, and consistency.
const replayHighHeldoutDelta = 0.5;
const replayHighConsistency = 0.66;

/// Replay Medium: motivating change in per-run correct rate.
const replayMediumMotivatingDelta = 0.5;

/// Noise: change in noise + wrong per run per PR on negatives.
const noiseHighDelta = 0.0;
const noiseMediumDelta = 0.33;
const noiseRejectDelta = 1.0;

/// Fidelity: below this share of bot locations reproduced, suggestions that
/// affect the bot drop one level.
const fidelityThreshold = 0.40;

/// A case is consistent when correct in at least this fraction of runs.
const consistentShare = 2 / 3;

const levels = ['Reject', 'Low', 'Medium', 'High'];
const arms = ['baseline', 'candidate'];

/// Summaries that suggest the reviewer could not read its inputs.
final _unreadable = RegExp(
  r"permission|could not (read|access)|couldn't (read|open)|based on the diff|from the diff alone|diff[- ]only review",
  caseSensitive: false,
);

/// GCA encodes severity as an image in the comment body.
const _botSeverities = {
  'critical.svg': 'critical',
  'high-priority.svg': 'high',
  'medium-priority.svg': 'medium',
  'low-priority.svg': 'low',
};

typedef Section = ({Map<String, Object?> json, String md});

double? _ratio(int a, int b) => b == 0 ? null : a / b;

String _fixed(double? v) => v == null ? 'n/a' : v.toStringAsFixed(2);

void main(List<String> argv) {
  var args = parseArgs(argv);
  var options = args.options;
  if (args.positional.length != 1) usageError(_usage);
  var command = args.positional.single;
  var runDir = options['run'] ?? usageError('Missing --run.\n$_usage');
  runDir = Directory(runDir).absolute.path;
  var evalDir = options['eval'] ?? Directory(runDir).parent.path;
  var s = Scorer(runDir, loadEval(evalDir), evalDir);
  String bot() =>
      options['bot'] ??
      loadConfig(path: options['config']).repo(s.eval.repo).bot;

  Section section;
  switch (command) {
    case 'validate':
      section = s.validate();
    case 'replay':
      section = s.replay();
    case 'noise':
      section = s.noise();
    case 'fidelity':
      var corpus = options['corpus'] ?? usageError('Missing --corpus.');
      section = s.fidelity(corpus, bot());
    case 'rubric':
      section = s.rubric(s.replay(), s.judged ? s.noise() : null,
          s.corpusPath == null ? null : s.fidelity(s.corpusPath!, bot()));
    case 'all':
      var validate = s.validate();
      var json = <String, Object?>{'validate': validate.json};
      var md = StringBuffer(validate.md);
      if (validate.json['ok'] == true) {
        var replay = s.replay();
        var noise = s.judged ? s.noise() : null;
        var fidelity =
            s.corpusPath == null ? null : s.fidelity(s.corpusPath!, bot());
        var rubric = s.rubric(replay, noise, fidelity);
        for (var (name, part) in [
          ('replay', replay),
          ('noise', noise),
          ('fidelity', fidelity),
          ('rubric', rubric),
        ]) {
          if (part == null) continue;
          json[name] = part.json;
          md.write('\n${part.md}');
        }
        writeJson('$runDir/score.json', json);
      }
      section = (json: json, md: md.toString());
    default:
      usageError('Unknown subcommand "$command".\n$_usage');
  }
  stdout.write(section.md);
  if (options['output-file'] case var path?) writeJson(path, section.json);
  if (s.problems.isNotEmpty) {
    stderr.writeln('Problems:\n${s.problems.join('\n')}');
    exit(exitFailure);
  }
}

const _usage =
    'Usage: dart run score.dart <validate|replay|noise|fidelity|rubric|all> '
    '--run <runDir> [--eval <evalDir>] [--corpus <file.jsonl>] '
    '[--bot <login>] [--config <path>] [--output-file <file.json>]';

final class Scorer {
  Scorer(this.runDir, this.eval, this.evalDir) {
    var manifest = readJson('$runDir/tasks.json') as Map<String, Object?>;
    armNames = {
      for (var e in (manifest['arms'] as Map).entries)
        e.key as String: e.value as String,
    };
    tasks = [
      for (var t in manifest['tasks'] as List) t as Map<String, Object?>,
    ];
  }

  final String runDir;
  final String evalDir;
  final Eval eval;

  /// Blinded arm (`arm1`/`arm2`) to `baseline`/`candidate`.
  late final Map<String, String> armNames;
  late final List<Map<String, Object?>> tasks;

  /// Input problems that make the command exit with [exitFailure].
  final problems = <String>[];

  late final Map<String, Map<String, Object?>?> _results = {
    for (var t in tasks) t['id'] as String: _load(t),
  };

  String get primary => eval.models.first.label;
  bool get judged => File('$runDir/judge/tasks.json').existsSync();
  String? get corpusPath =>
      eval.corpus == null ? null : '$evalDir/${eval.corpus}';

  Map<String, Object?>? _load(Map<String, Object?> task) {
    try {
      var json = jsonDecode(File(_output(task)).readAsStringSync());
      return _schemaError(json) == null && json['inputError'] == null
          ? json as Map<String, Object?>
          : null;
    } on Object {
      return null;
    }
  }

  String _output(Map<String, Object?> task) =>
      task['output'] as String? ??
      '$runDir/results/${task['model']}/${task['case']}-${task['arm']}'
          '-r${task['run']}.json';

  /// Comments of each valid result for [model], [caseId], and [arm]
  /// (`baseline`/`candidate`), keyed by run number.
  Map<int, List<Map<String, Object?>>> runs(
      String model, String caseId, String arm) {
    return {
      for (var t in tasks)
        if (t['model'] == model &&
            t['case'] == caseId &&
            armNames[t['arm']] == arm &&
            _results[t['id']] != null)
          t['run'] as int: [
            for (var c in _results[t['id']]!['comments'] as List)
              if ((c as Map)['severity'] != 'low') c as Map<String, Object?>,
          ],
    };
  }

  List<String> get models => [
        for (var m in eval.models)
          if (tasks.any((t) => t['model'] == m.label)) m.label,
      ];

  // ---------------------------------------------------------------------
  // validate

  Section validate() {
    var missing = <String>[], unparsable = <String>[], warnings = <String>[];
    var invalid = <String, String>{}, inputErrors = <String, String>{};
    for (var t in tasks) {
      var id = t['id'] as String;
      var file = File(_output(t));
      if (!file.existsSync()) {
        missing.add(id);
        continue;
      }
      Object? json;
      try {
        json = jsonDecode(file.readAsStringSync());
      } on FormatException {
        unparsable.add(id);
        continue;
      }
      if (_schemaError(json) case var error?) {
        invalid[id] = error;
      } else if ((json as Map)['inputError'] case String reason) {
        inputErrors[id] = reason;
      } else if (_unreadable.hasMatch(json['summary'] as String)) {
        warnings.add(id);
      }
    }
    var ok = missing.isEmpty &&
        unparsable.isEmpty &&
        invalid.isEmpty &&
        inputErrors.isEmpty;
    if (!ok) problems.add('Some results are missing or invalid; rerun them.');
    var bad = missing.length +
        unparsable.length +
        invalid.length +
        inputErrors.length;
    var md = StringBuffer('## Validate\n\n')
      ..writeln('${tasks.length - bad}/${tasks.length} results valid.');
    void list(String label, Iterable<String> lines) {
      if (lines.isEmpty) return;
      md.writeln('\n$label:');
      for (var line in lines) {
        md.writeln('- $line');
      }
    }

    list('Missing', missing);
    list('Unparsable', unparsable);
    list('Invalid', [for (var e in invalid.entries) '${e.key}: ${e.value}']);
    list('inputError',
        [for (var e in inputErrors.entries) '${e.key}: ${e.value}']);
    list('Warning: summary mentions unreadable inputs (check, not a failure)',
        warnings);
    return (
      json: {
        'ok': ok,
        'tasks': tasks.length,
        'missing': missing,
        'unparsable': unparsable,
        'invalid': invalid,
        'inputError': inputErrors,
        'warnings': warnings,
      },
      md: md.toString(),
    );
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

  Section replay() {
    var json = <String, Object?>{};
    var md = StringBuffer('## Replay\n');
    var scored = [
      for (var c in eval.cases)
        if (c.want != 'none') c,
    ];
    var otherGroups = eval.pathGroups.keys.toList();
    for (var model in models) {
      // case id -> arm -> stats
      var stats = <String, Map<String, Map<String, Object?>>>{};
      for (var c in eval.cases) {
        for (var arm in arms) {
          var rs = runs(model, c.id, arm);
          bool flagsIn(List<Map<String, Object?>> cs, String g) =>
              cs.any((k) => eval.flags(k, g));
          (stats[c.id] ??= {})[arm] = {
            'runs': rs.length,
            'flagged': rs.values.where((cs) => flagsIn(cs, c.group)).length,
            'flaggedRuns': [
              for (var e in rs.entries)
                if (flagsIn(e.value, c.group)) e.key,
            ],
            'kept': rs.values.fold<int>(0, (a, cs) => a + cs.length),
            'otherGroups': {
              for (var g in otherGroups)
                if (g != c.group)
                  g: rs.values.where((cs) => flagsIn(cs, g)).length,
            },
          };
        }
      }
      int n(String id, String arm, String key) => stats[id]![arm]![key] as int;
      int correct(EvalCase c, String arm) => c.want == 'flag'
          ? n(c.id, arm, 'flagged')
          : n(c.id, arm, 'runs') - n(c.id, arm, 'flagged');
      int sum(Iterable<EvalCase> cs, int Function(EvalCase) f) =>
          cs.fold(0, (a, c) => a + f(c));

      // Per set and want: flagged runs, total runs, correct runs.
      var sets = <String, Object?>{};
      for (var set in caseSets) {
        for (var want in ['no-flag', 'flag']) {
          var cs = scored.where((c) => c.set == set && c.want == want);
          if (cs.isEmpty) continue;
          sets['$set/$want'] = {
            'cases': cs.length,
            for (var arm in arms)
              arm: {
                'flagged': sum(cs, (c) => n(c.id, arm, 'flagged')),
                'correct': sum(cs, (c) => correct(c, arm)),
                'runs': sum(cs, (c) => n(c.id, arm, 'runs')),
              },
          };
        }
      }
      // Change in per-run correct rate, per set (scored cases).
      var delta = <String, Object?>{};
      for (var set in caseSets) {
        var cs = scored.where((c) => c.set == set);
        double? rate(String arm) => _ratio(sum(cs, (c) => correct(c, arm)),
            sum(cs, (c) => n(c.id, arm, 'runs')));
        if ((rate('baseline'), rate('candidate')) case (var b?, var c?)) {
          delta[set] = c - b;
        }
      }
      var heldout = scored.where((c) => c.set == 'heldout').toList();
      var consistency = {
        for (var arm in arms)
          arm: heldout
              .where((c) =>
                  correct(c, arm) >= consistentShare * n(c.id, arm, 'runs'))
              .length,
      };
      var negatives = eval.cases.where((c) => c.set == 'negative');
      var keptMean = {
        for (var arm in arms)
          arm: _ratio(sum(negatives, (c) => n(c.id, arm, 'kept')),
              sum(negatives, (c) => n(c.id, arm, 'runs'))),
      };
      var baselineCorrect = sum(scored, (c) => correct(c, 'baseline'));
      var candidateCorrect = sum(scored, (c) => correct(c, 'candidate'));
      var lost = [
        for (var c in scored)
          if (c.want == 'flag' &&
              correct(c, 'candidate') < correct(c, 'baseline'))
            c.id,
      ];
      var change = candidateCorrect - baselineCorrect;
      var verdict = change < 0 || lost.isNotEmpty
          ? 'hurts'
          : change > 0
              ? 'helps'
              : 'no effect';
      var runCount = eval.models.firstWhere((m) => m.label == model).runs;
      json[model] = {
        'cases': stats,
        'sets': sets,
        'delta': delta,
        'consistency': {...consistency, 'cases': heldout.length},
        'negativeKeptMean': keptMean,
        'verdict': {
          'verdict': verdict,
          'baselineCorrect': baselineCorrect,
          'candidateCorrect': candidateCorrect,
          'runs': sum(scored, (c) => n(c.id, 'baseline', 'runs')),
          'lostFlagCases': lost,
        },
      };

      String frac(String id, String arm, [String key = 'flagged']) =>
          '${n(id, arm, key)}/${n(id, arm, 'runs')}';
      md
        ..writeln('\n### $model ($runCount run(s) per arm)\n')
        ..writeln('Runs that flag the concern (in the case\'s path group):\n')
        ..writeln('| Case | Set | Group | Want | Baseline | Candidate |')
        ..writeln('|---|---|---|---|---|---|');
      for (var c in eval.cases) {
        md.writeln('| ${c.id} | ${c.set} | ${c.group} | ${c.want} '
            '| ${frac(c.id, 'baseline')} | ${frac(c.id, 'candidate')} |');
      }
      md.writeln('\n| Set | Want | Cases | Measure | Baseline | Candidate |\n'
          '|---|---|---|---|---|---|');
      for (var MapEntry(key: key, value: v as Map) in sets.entries) {
        var [set, want] = key.split('/');
        String f(String arm) => '${v[arm]['flagged']}/${v[arm]['runs']} runs';
        md.writeln('| $set | $want | ${v['cases']} '
            '| ${want == 'flag' ? 'recall' : 'false flags'} '
            '| ${f('baseline')} | ${f('candidate')} |');
      }
      if (heldout.isNotEmpty) {
        md.writeln('\nHeld-out consistency (correct in >= 2/3 of '
            '$runCount run(s)): baseline ${consistency['baseline']}/'
            '${heldout.length}, candidate ${consistency['candidate']}/'
            '${heldout.length}.');
      }
      if (negatives.isNotEmpty) {
        md.writeln('Negatives: mean kept comments per run: baseline '
            '${_fixed(keptMean['baseline'])}, candidate '
            '${_fixed(keptMean['candidate'])} (${negatives.length} PRs).');
      }
      int otherFlags(String id, String arm, String g) =>
          (stats[id]![arm]!['otherGroups'] as Map)[g] as int;
      var other = [
        for (var c in eval.cases)
          for (var g in (stats[c.id]!['baseline']!['otherGroups'] as Map).keys)
            if (otherFlags(c.id, 'baseline', g) +
                    otherFlags(c.id, 'candidate', g) >
                0)
              '${c.id} in `$g`: baseline ${otherFlags(c.id, 'baseline', g)}/'
                  '${n(c.id, 'baseline', 'runs')}, candidate '
                  '${otherFlags(c.id, 'candidate', g)}/'
                  '${n(c.id, 'candidate', 'runs')}',
      ];
      if (otherGroups.length > 1) {
        md.writeln('Flags in other path groups (informational): '
            '${other.isEmpty ? 'none' : other.join('; ')}.');
      }
      md.writeln('\n**Check verdict: $verdict.** Correct runs over '
          '${scored.length} scored cases: baseline $baselineCorrect, '
          'candidate $candidateCorrect of '
          '${sum(scored, (c) => n(c.id, 'baseline', 'runs'))} each '
          '(delta ${change >= 0 ? '+' : ''}$change)'
          '${lost.isEmpty ? '' : '; loses want=flag case(s) ${lost.join(', ')}'}.');
    }
    return (json: json, md: md.toString());
  }

  // ---------------------------------------------------------------------
  // noise

  Section noise() {
    var dir = '$runDir/judge';
    var mapping =
        (readJson('$dir/tasks.json') as Map)['mapping'] as Map? ?? const {};
    // model -> set -> arm -> [bad, badNonTarget]
    var counts = <String, Map<String, Map<String, List<int>>>>{};
    var judgedCases = <EvalCase>[];
    var concernFlags = 0, concernWrong = 0;
    for (var c in eval.cases) {
      var findingsFile = File('$dir/${c.id}.findings.json');
      if (!findingsFile.existsSync()) continue;
      judgedCases.add(c);
      var findings = readJson(findingsFile.path) as List;
      var verdictsFile = '$dir/${c.id}.verdicts.json';
      if (findings.isNotEmpty && !File(verdictsFile).existsSync()) {
        problems.add('${c.id}: no verdicts');
        continue;
      }
      var verdicts = findings.isEmpty
          ? const {}
          : {
              for (var v in (readJson(verdictsFile) as Map)['verdicts'] as List)
                (v as Map)['id']: v['verdict'],
            };
      for (var f in findings) {
        var finding = f as Map<String, Object?>;
        var id = finding['id'];
        var m = (mapping[id] ?? (mapping[c.id] as Map?)?[id]) as Map?;
        var verdict = verdicts[id];
        if (m == null || verdict == null) {
          problems.add('${c.id}: finding $id is '
              '${m == null ? 'not in the mapping' : 'unjudged'}');
          continue;
        }
        var arm = armNames[m['arm']]!;
        var target = eval.flags(finding, c.group);
        var bad = verdict == 'noise' || verdict == 'wrong';
        var agg = ((counts[m['model'] as String? ?? primary] ??= {})[c.set] ??=
            {})[arm] ??= [0, 0];
        if (bad) agg[0]++;
        if (bad && !target) agg[1]++;
        if (arm == 'baseline' && target && c.want == 'no-flag') {
          concernFlags++;
          if (verdict == 'wrong') concernWrong++;
        }
      }
    }
    var json = <String, Object?>{};
    var md = StringBuffer('## Noise (blind judge)\n');
    for (var MapEntry(key: model, value: bySet) in counts.entries) {
      var sets = <String, Object?>{};
      md
        ..writeln('\n### $model: noise + wrong per run per PR\n')
        ..writeln('| Set | PRs | Baseline | Candidate | Delta '
            '| Non-target baseline | Non-target candidate | Delta |')
        ..writeln('|---|---|---|---|---|---|---|---|');
      for (var set in caseSets) {
        var cs = judgedCases.where((c) => c.set == set).toList();
        if (cs.isEmpty) continue;
        double mean(String arm, int i) {
          var runCount =
              cs.fold<int>(0, (a, c) => a + runs(model, c.id, arm).length);
          return runCount == 0 ? 0 : (bySet[set]?[arm]?[i] ?? 0) / runCount;
        }

        var row = {
          for (var arm in arms)
            arm: {'all': mean(arm, 0), 'nonTarget': mean(arm, 1)},
        };
        sets[set] = {...row, 'cases': cs.length};
        String d(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(2)}';
        String m(String arm, String k) => row[arm]![k]!.toStringAsFixed(2);
        md.writeln('| $set | ${cs.length} | ${m('baseline', 'all')} '
            '| ${m('candidate', 'all')} '
            '| ${d(row['candidate']!['all']! - row['baseline']!['all']!)} '
            '| ${m('baseline', 'nonTarget')} | ${m('candidate', 'nonTarget')} '
            '| ${d(row['candidate']!['nonTarget']! - row['baseline']!['nonTarget']!)} |');
      }
      json[model] = sets;
    }
    md.writeln('\nNon-target excludes findings that flag the concern. '
        'Baseline findings that flag the concern on want=no-flag cases '
        'judged wrong: $concernWrong of $concernFlags.');
    json['baselineConcernFlags'] = {
      'flags': concernFlags,
      'wrong': concernWrong,
    };
    return (json: json, md: md.toString());
  }

  // ---------------------------------------------------------------------
  // fidelity

  Section fidelity(String corpusPath, String bot) {
    var file = File(corpusPath);
    if (!file.existsSync()) {
      problems.add('Missing corpus: $corpusPath');
      return (json: {'error': 'missing corpus'}, md: '');
    }
    var prs = <int, Map<String, Object?>>{};
    for (var line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      var pr = jsonDecode(line) as Map<String, Object?>;
      prs[pr['number'] as int] = pr;
    }
    var motivating = [
      for (var c in eval.cases)
        if (c.set == 'motivating' && c.pr != null) c,
    ];
    // Distinct (case, path) where the bot flagged the concern.
    var locations = <(EvalCase, String)>{};
    var everyFileFlagged = true;
    for (var c in motivating) {
      var pr = prs[c.pr];
      if (pr == null) {
        problems.add('${c.id}: PR ${c.pr} not in the corpus');
        continue;
      }
      var paths = <String>{};
      for (var comment in pr['comments'] as List) {
        var k = comment as Map<String, Object?>;
        var body = k['body'] as String? ?? '';
        var severity = _botSeverities.entries
                .where((e) => body.contains(e.key))
                .firstOrNull
                ?.value ??
            '';
        if (k['author'] == bot &&
            k['kind'] == 'inline' &&
            (k['commitId'] as String? ?? '').startsWith(c.commit!) &&
            eval.flags({...k, 'severity': severity}, c.group)) {
          paths.add(k['path'] as String);
        }
      }
      locations.addAll([for (var p in paths) (c, p)]);
      if (paths.isNotEmpty &&
          !_diffFiles(c, pr).where((p) => eval.inGroup(p, c.group)).every(
                paths.contains,
              )) {
        everyFileFlagged = false;
      }
    }
    var sorted = locations.toList()
      ..sort((a, b) => '${a.$1.id} ${a.$2}'.compareTo('${b.$1.id} ${b.$2}'));
    var json = <String, Object?>{
      'bot': bot,
      'locations': [
        for (var (c, p) in sorted) {'case': c.id, 'path': p},
      ],
      'recallOnly': locations.isNotEmpty && everyFileFlagged,
    };
    var md = StringBuffer('## Bot fidelity (baseline arm vs `$bot`)\n\n');
    if (locations.isEmpty) {
      md.writeln('The bot posted no comments flagging the concern on '
          'motivating cases at the reviewed commits; fidelity not measured.');
      return (json: json, md: md.toString());
    }
    md
      ..writeln('${locations.length} bot locations (distinct case + file) '
          'across ${motivating.length} motivating PRs.\n')
      ..writeln('| Model | Location-runs reproduced | Per run |')
      ..writeln('|---|---|---|');
    var perModel = <String, Object?>{};
    for (var model in models) {
      var hits = 0, total = 0;
      var perRun = <int, int>{};
      var perLocation = <String, int>{};
      for (var (c, path) in sorted) {
        for (var MapEntry(key: run, value: comments)
            in runs(model, c.id, 'baseline').entries) {
          total++;
          if (comments
              .any((k) => k['path'] == path && eval.flags(k, c.group))) {
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
      perModel[model] = {
        'reproduced': hits,
        'locationRuns': total,
        'rate': total == 0 ? null : hits / total,
        'perRun': {for (var r in runNumbers) '$r': perRun[r] ?? 0},
        'perLocation': perLocation,
      };
      md.writeln('| $model | $hits/$total'
          '${total == 0 ? '' : ' (${(100 * hits / total).round()}%)'} '
          '| ${[
        for (var r in runNumbers) '${perRun[r] ?? 0}/${locations.length}'
      ].join(', ')} |');
    }
    json['models'] = perModel;
    if (json['recallOnly'] == true) {
      md.writeln('\nThe bot flagged every in-group file of these diffs, so '
          'this measures recall only: a reviewer that flags everything '
          'scores 100%.');
    }
    return (json: json, md: md.toString());
  }

  /// Files changed by [c]: from the prepared diff if present, else the
  /// corpus PR's final file list.
  List<String> _diffFiles(EvalCase c, Map<String, Object?> pr) {
    var diff = File('$runDir/work/cases/${c.id}/diff.patch');
    if (diff.existsSync()) {
      return [
        for (var m in RegExp(r'^diff --git a/\S+ b/(\S+)', multiLine: true)
            .allMatches(diff.readAsStringSync()))
          m[1]!,
      ];
    }
    return [
      for (var f in pr['files'] as List? ?? const []) (f as Map)['path'],
    ];
  }

  // ---------------------------------------------------------------------
  // rubric

  Section rubric(Section replay, Section? noise, Section? fidelity) {
    var rows = <Map<String, Object?>>[];
    void row(String name, String result, String level) =>
        rows.add({'row': name, 'result': result, 'level': level});

    // Evidence.
    var ev = eval.evidence;
    var weighted = (ev['weightedComments'] as num?) ?? 0;
    var prCount = (ev['prs'] as num?) ?? 0;
    var maintainer = ev['maintainer'] == true;
    var contradiction = ev['contradiction'] == true;
    var reviewers = [for (var r in ev['reviewers'] as List? ?? const []) r];
    var evidenceLevel = weighted >= evidenceHighComments &&
            prCount >= evidenceHighPrs &&
            maintainer
        ? 3
        : weighted >= evidenceMediumComments || maintainer
            ? 2
            : weighted > 0
                ? 1
                : 0;
    if (contradiction && eval.type == 'fix') evidenceLevel = 3;
    row(
      'Evidence',
      '$weighted weighted comments across $prCount PRs, reviewers: '
          '${reviewers.isEmpty ? 'none' : reviewers.join(', ')}'
          '${maintainer ? ' (maintainer)' : ''}'
          '${reviewers.length == 1 ? ', single-reviewer' : ''}'
          '${contradiction ? '; deterministic contradiction' : ''}',
      levels[evidenceLevel],
    );

    // Replay (primary model).
    var p = replay.json[primary] as Map<String, Object?>?;
    int replayLevel;
    if (p == null) {
      var byInspection = eval.type == 'fix' && contradiction;
      replayLevel = byInspection ? 3 : 1;
      row(
          'Replay',
          byInspection
              ? 'not run; verified by inspection, not replay'
              : 'not run; unverified (capped at Low)',
          levels[replayLevel]);
    } else {
      var delta = p['delta'] as Map;
      var dh = delta['heldout'] as double?;
      var dm = delta['motivating'] as double?;
      var cons = p['consistency'] as Map;
      var consistency = (cons['cases'] as int) == 0
          ? null
          : (cons['candidate'] as int) / (cons['cases'] as int);
      var verdict = p['verdict'] as Map;
      replayLevel = verdict['verdict'] == 'hurts'
          ? 0
          : dh != null &&
                  dh >= replayHighHeldoutDelta &&
                  consistency! >= replayHighConsistency
              ? 3
              : (dm ?? 0) >= replayMediumMotivatingDelta &&
                      (dh == null || dh > 0)
                  ? 2
                  : (dm ?? 0) > 0 || (dh ?? 0) > 0
                      ? 1
                      : 0;
      String d(double? v) =>
          v == null ? 'n/a' : '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';
      row(
        'Replay',
        '$primary: held-out delta ${d(dh)} (>= $replayHighHeldoutDelta for '
            'High), consistency ${cons['candidate']}/${cons['cases']} '
            '(>= $replayHighConsistency), motivating delta ${d(dm)}; check '
            'verdict ${verdict['verdict']}'
            '${dh == null ? '; motivating only (capped at Medium)' : ''}',
        levels[replayLevel],
      );
    }

    // Noise (primary model, negatives).
    int? noiseLevel;
    var negatives = (noise?.json[primary] as Map?)?['negative'] as Map?;
    if (negatives == null) {
      row('Noise', noise == null ? 'not measured' : 'no judged negatives',
          'not measured');
    } else {
      var dn = ((negatives['candidate'] as Map)['all'] as double) -
          ((negatives['baseline'] as Map)['all'] as double);
      noiseLevel = dn <= noiseHighDelta
          ? 3
          : dn <= noiseMediumDelta
              ? 2
              : dn <= noiseRejectDelta
                  ? 1
                  : 0;
      var flags = noise!.json['baselineConcernFlags'] as Map;
      row(
        'Noise',
        'delta noise on negatives ${dn >= 0 ? '+' : ''}'
            '${dn.toStringAsFixed(2)} per run per PR '
            '(${negatives['cases']} PRs; <= $noiseHighDelta for High); '
            '${flags['wrong']}/${flags['flags']} baseline concern flags on '
            'want=no-flag cases judged wrong',
        levels[noiseLevel],
      );
    }

    var level = [evidenceLevel, replayLevel, if (noiseLevel != null) noiseLevel]
        .reduce((a, b) => a < b ? a : b);

    // Fidelity modifier (primary model).
    var f = ((fidelity?.json['models'] as Map?)?[primary] as Map?)?['rate']
        as double?;
    if (f == null) {
      row('Fidelity', 'not measured', 'no modifier');
    } else {
      var drop = f < fidelityThreshold &&
          (eval.affects == 'bot' || eval.affects == 'both');
      if (drop) level--;
      row(
        'Fidelity',
        '$primary reproduced ${(100 * f).round()}% of bot locations '
            '(threshold ${(100 * fidelityThreshold).round()}%)'
            '${fidelity!.json['recallOnly'] == true ? '; recall only' : ''}',
        drop ? 'drop one level' : 'no modifier',
      );
    }

    // Robustness (non-primary models).
    var others = [
      for (var m in models.skip(1))
        if (replay.json[m] case Map r)
          (m, (r['verdict'] as Map)['verdict'] as String),
    ];
    if (others.isEmpty) {
      row('Robustness', 'not run', 'no modifier');
    } else {
      var notHelping = others.where((o) => o.$2 != 'helps');
      if (notHelping.isNotEmpty) level--;
      row(
        'Robustness',
        [for (var (m, v) in others) '$m: $v'].join(', '),
        notHelping.isEmpty ? 'no modifier' : 'drop one level',
      );
    }

    var overall = levels[level < 0 ? 0 : level];
    var md =
        StringBuffer('## Rubric\n\n| Row | Result | Level |\n|---|---|---|\n');
    for (var r in rows) {
      md.writeln('| ${r['row']} | ${r['result']} | ${r['level']} |');
    }
    md.writeln('\n**Overall: $overall.** Small samples: a structured '
        'judgment, not a statistical test.');
    return (json: {'rows': rows, 'overall': overall}, md: md.toString());
  }
}
