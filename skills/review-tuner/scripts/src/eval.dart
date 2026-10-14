/// The per-suggestion evaluation definition (`eval.json`) and the single rule
/// that decides whether a review comment "flags" the suggestion's concern.
///
/// See `references/formats.md` for the documented format.
library;

import 'cli.dart';

/// Comment severities, lowest first.
const severities = ['low', 'medium', 'high', 'critical'];

int severityRank(String s) => severities.indexOf(s.toLowerCase());

/// Whether a reviewer [comment] is kept for scoring and judging: a known
/// severity of at least `medium`.
bool isKept(Map<String, Object?> comment) =>
    severityRank(comment['severity'] as String? ?? '') >=
    severityRank('medium');

/// A case set. Every case states its expected outcome ([Want]) explicitly.
enum CaseSet { motivating, heldout, guard, negative, info }

/// A case's expected outcome.
enum Want {
  flag('flag'),
  noFlag('no-flag'),

  /// Informational: not scored.
  none('none');

  const Want(this.json);

  /// The spelling in `eval.json` and in reports.
  final String json;
}

/// What a suggestion does to the guidance.
enum ChangeType { add, edit, remove, fix }

/// Which reviewer reads the changed file.
enum Affects { bot, local, both }

/// A model to run: its `tier`, `runs` per arm, and report `label`.
typedef ModelSpec = ({String tier, int runs, String label});

/// The value of [values] spelled [raw] (by [spelling], default the enum
/// name), or a [fail] naming [field] and the allowed spellings.
T parseEnum<T extends Enum>(
  List<T> values,
  Object? raw,
  String field, {
  String Function(T)? spelling,
}) {
  String spell(T v) => spelling?.call(v) ?? v.name;
  for (var v in values) {
    if (spell(v) == raw) return v;
  }
  fail('$field "$raw" must be one of ${values.map(spell).join(', ')}');
}

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
    var id = json['id'] as String;
    var c = EvalCase(
      id: id,
      set: parseEnum(CaseSet.values, json['set'], 'Case $id: set'),
      want: parseEnum(Want.values, json['want'] ?? 'none', 'Case $id: want',
          spelling: (w) => w.json),
      pr: json['pr'] as int?,
      commit: json['commit'] as String?,
      patch: json['patch'] as String?,
      group: json['group'] as String? ?? 'any',
    );
    var real = c.pr != null && c.commit != null;
    if (real == (c.patch != null) || (c.pr != null && c.commit == null)) {
      fail('Case $id: needs exactly one of pr + commit, or patch');
    }
    return c;
  }

  final String id;
  final CaseSet set;
  final Want want;
  final int? pr;
  final String? commit;

  /// Synthetic patch path, relative to the eval directory. A synthetic case
  /// has no `pr`; its optional `commit` is the commit the patch applies to.
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
    List<String> tags = const [],
  }) : tags = [for (var t in tags) t.toLowerCase()];

  factory Concern.fromJson(Map<String, Object?> json) {
    var minSeverity = json['minSeverity'] as String? ?? 'high';
    if (severityRank(minSeverity) < 0) {
      fail('concern.minSeverity "$minSeverity" must be one of '
          '${severities.join(', ')}');
    }
    return Concern(
      cite: _pattern('cite', json['cite'] as String),
      objection: switch (json['objection']) {
        String o => _pattern('objection', o),
        _ => null,
      },
      minSeverity: minSeverity,
      tags: [for (var t in json['tags'] as List? ?? const []) t as String],
    );
  }

  static RegExp _pattern(String field, String pattern) {
    if (pattern.startsWith('TODO')) {
      fail('concern.$field is still the starter TODO; replace it');
    }
    try {
      return RegExp(pattern, caseSensitive: false);
    } on FormatException catch (e) {
      fail('Invalid concern.$field regex: ${e.message}');
    }
  }

  /// Text that ties a comment to the guidance rule.
  final RegExp cite;

  /// Optional broader objection wording that counts at [minSeverity]+.
  final RegExp? objection;
  final String minSeverity;

  /// Severity tags (e.g. `[MUST-FIX]`), lower-cased, that count as a flag
  /// when the comment also cites the rule, regardless of severity.
  final List<String> tags;

  /// Whether [text] carries one of [tags] (case-insensitive).
  bool tagged(String text) {
    var lower = text.toLowerCase();
    return tags.any(lower.contains);
  }
}

/// Evidence counts for the rubric's Evidence row.
typedef Evidence = ({
  num weightedComments,
  num prs,
  List<String> reviewers,
  bool maintainer,
  bool contradiction,
});

Evidence _evidence(Map<String, Object?> json) => (
      weightedComments: json['weightedComments'] as num? ?? 0,
      prs: json['prs'] as num? ?? 0,
      reviewers: [for (var r in json['reviewers'] as List? ?? const []) '$r'],
      maintainer: json['maintainer'] == true,
      contradiction: json['contradiction'] == true,
    );

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
    this.evidence,
    this.policy = const [],
    this.corpus,
  });

  factory Eval.fromJson(Map<String, Object?> json) {
    var eval = Eval(
      id: json['id'] as String,
      repo: json['repo'] as String,
      type: parseEnum(ChangeType.values, json['type'] ?? 'edit', 'type'),
      affects: parseEnum(Affects.values, json['affects'] ?? 'bot', 'affects'),
      models: [
        for (var m in json['models'] as List? ?? const [defaultModel])
          (
            tier: (m as Map)['tier'] as String,
            runs: m['runs'] as int? ?? 1,
            label: m['label'] as String? ?? m['tier'] as String,
          ),
      ],
      concern: Concern.fromJson(json['concern'] as Map<String, Object?>),
      pathGroups: {
        for (var e in (json['pathGroups'] as Map? ?? const {}).entries)
          e.key as String: [for (var p in e.value as List) p as String],
      },
      cases: [
        for (var c in json['cases'] as List)
          EvalCase.fromJson(c as Map<String, Object?>),
      ],
      evidence: switch (json['evidence']) {
        Map<String, Object?> e => _evidence(e),
        _ => null,
      },
      policy: [for (var p in json['policy'] as List? ?? const []) p as String],
      corpus: json['corpus'] as String?,
    );
    for (var c in eval.cases) {
      if (c.group != 'any' && !eval.pathGroups.containsKey(c.group)) {
        fail('Case ${c.id}: group "${c.group}" is not "any" or a key of '
            'pathGroups');
      }
    }
    return eval;
  }

  /// The model used when `eval.json` lists none: one run on the agent's own
  /// model.
  static const defaultModel = {'tier': 'inherit', 'runs': 1};

  final String id;
  final String repo;
  final ChangeType type;
  final Affects affects;

  /// Models to run; the first is the primary. Never pooled.
  final List<ModelSpec> models;
  final Concern concern;

  /// Named path groups: a path is in a group if it contains any listed
  /// substring. `any` always matches.
  final Map<String, List<String>> pathGroups;
  final List<EvalCase> cases;

  /// Inputs to the rubric's Evidence row; null if `eval.json` has none.
  final Evidence? evidence;

  /// Owner-maintained facts given to the judge as ground truth.
  final List<String> policy;

  /// Optional corpus path (relative to the eval dir) for bot fidelity.
  final String? corpus;

  /// The primary model (the first in [models]).
  ModelSpec get primary => models.first;

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
    return (severe && (cites || objects)) || (cites && concern.tagged(text));
  }
}

/// Loads `<evalDir>/eval.json`.
Eval loadEval(String evalDir) =>
    Eval.fromJson(readJson('$evalDir/eval.json') as Map<String, Object?>);
