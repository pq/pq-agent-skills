/// The per-suggestion evaluation definition (`eval.json`) and the single rule
/// that decides whether a review comment "flags" the suggestion's concern.
///
/// See `references/formats.md` for the documented format.
library;

import 'config.dart';

/// Comment severities, lowest first.
const severities = ['low', 'medium', 'high', 'critical'];

int severityRank(String s) => severities.indexOf(s.toLowerCase());

/// Case sets. Every case states its expected outcome (`want`) explicitly.
const caseSets = ['motivating', 'heldout', 'guard', 'negative', 'info'];

/// One evaluation case: a real PR at the commit a reviewer saw, or a
/// synthetic patch.
final class EvalCase {
  EvalCase({
    required this.id,
    required this.set,
    required this.want,
    this.pr,
    this.commit,
    this.patch,
    this.group = 'any',
  });

  factory EvalCase.fromJson(Map<String, Object?> json) {
    var c = EvalCase(
      id: json['id'] as String,
      set: json['set'] as String,
      want: json['want'] as String? ?? 'none',
      pr: json['pr'] as int?,
      commit: json['commit'] as String?,
      patch: json['patch'] as String?,
      group: json['group'] as String? ?? 'any',
    );
    if (!caseSets.contains(c.set)) {
      usageError('Case ${c.id}: unknown set "${c.set}"');
    }
    if (!const ['flag', 'no-flag', 'none'].contains(c.want)) {
      usageError('Case ${c.id}: want must be flag, no-flag, or none');
    }
    if ((c.pr == null || c.commit == null) && c.patch == null) {
      usageError('Case ${c.id}: needs pr + commit, or patch');
    }
    return c;
  }

  final String id;

  /// One of [caseSets].
  final String set;

  /// `flag`, `no-flag`, or `none` (informational, not scored).
  final String want;
  final int? pr;
  final String? commit;

  /// Synthetic patch path, relative to the eval directory.
  final String? patch;

  /// Path group the concern is checked in (`any` = all paths).
  final String group;

  bool get synthetic => patch != null;
}

/// What counts as a review comment raising the concern.
final class Concern {
  Concern({
    required this.cite,
    this.objection,
    this.minSeverity = 'high',
    this.tags = const [],
  });

  factory Concern.fromJson(Map<String, Object?> json) => Concern(
        cite: RegExp(json['cite'] as String, caseSensitive: false),
        objection: switch (json['objection']) {
          String o => RegExp(o, caseSensitive: false),
          _ => null,
        },
        minSeverity: json['minSeverity'] as String? ?? 'high',
        tags: [for (final t in json['tags'] as List? ?? const []) t as String],
      );

  /// Text that ties a comment to the guidance rule.
  final RegExp cite;

  /// Optional broader objection wording that counts at [minSeverity]+.
  final RegExp? objection;
  final String minSeverity;

  /// Severity tags (e.g. `[MUST-FIX]`) that count as a flag when the comment
  /// also cites the rule, regardless of severity.
  final List<String> tags;
}

/// The evaluation definition.
final class Eval {
  Eval({
    required this.id,
    required this.repo,
    required this.type,
    required this.affects,
    required this.models,
    required this.concern,
    required this.pathGroups,
    required this.cases,
    required this.evidence,
    this.policy = const [],
    this.corpus,
  });

  factory Eval.fromJson(Map<String, Object?> json) => Eval(
        id: json['id'] as String,
        repo: json['repo'] as String,
        type: json['type'] as String? ?? 'edit',
        affects: json['affects'] as String? ?? 'bot',
        models: [
          for (final m in json['models'] as List? ??
              const [
                {'tier': 'inherit', 'runs': 1},
              ])
            (
              tier: (m as Map)['tier'] as String,
              runs: m['runs'] as int? ?? 1,
              label: m['label'] as String? ?? m['tier'] as String,
            ),
        ],
        concern: Concern.fromJson(json['concern'] as Map<String, Object?>),
        pathGroups: {
          for (final e in (json['pathGroups'] as Map? ?? const {}).entries)
            e.key as String: [for (final p in e.value as List) p as String],
        },
        cases: [
          for (final c in json['cases'] as List)
            EvalCase.fromJson(c as Map<String, Object?>),
        ],
        evidence: json['evidence'] as Map<String, Object?>? ?? const {},
        policy: [
          for (final p in json['policy'] as List? ?? const []) p as String
        ],
        corpus: json['corpus'] as String?,
      );

  final String id;
  final String repo;

  /// `add`, `edit`, `remove`, or `fix`.
  final String type;

  /// Which reviewer reads the changed file: `bot`, `local`, or `both`.
  final String affects;

  /// Models to run; the first is the primary. Never pooled.
  final List<({String tier, int runs, String label})> models;
  final Concern concern;

  /// Named path groups: a path is in a group if it contains any listed
  /// substring. `any` always matches.
  final Map<String, List<String>> pathGroups;
  final List<EvalCase> cases;

  /// Evidence counts for the rubric: `weightedComments`, `prs`,
  /// `reviewers`, `maintainer`, `contradiction`.
  final Map<String, Object?> evidence;

  /// Owner-maintained facts given to the judge as ground truth.
  final List<String> policy;

  /// Optional corpus path (relative to the eval dir) for bot fidelity.
  final String? corpus;

  bool inGroup(String path, String group) =>
      group == 'any' ||
      (pathGroups[group] ?? const []).any((p) => path.contains(p));

  /// The single flag rule: the comment is in the case's path group, is not
  /// `low`, and either (a) is at least [Concern.minSeverity] and matches the
  /// citation or objection wording, or (b) cites the rule and carries one of
  /// [Concern.tags].
  bool flags(Map<String, Object?> comment, String group) {
    var path = comment['path'] as String? ?? '';
    var severity = (comment['severity'] as String? ?? '').toLowerCase();
    var text = '${comment['title'] ?? ''} ${comment['body'] ?? ''}';
    if (!inGroup(path, group) || severity == 'low') return false;
    var cites = concern.cite.hasMatch(text);
    var objects = concern.objection?.hasMatch(text) ?? false;
    var severe = severityRank(severity) >= severityRank(concern.minSeverity);
    var tagged = concern.tags.any(text.contains);
    return (severe && (cites || objects)) || (cites && tagged);
  }
}

/// Loads `<evalDir>/eval.json`.
Eval loadEval(String evalDir) =>
    Eval.fromJson(readJson('$evalDir/eval.json') as Map<String, Object?>);
