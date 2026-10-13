/// Shared configuration and CLI helpers for review-tuner scripts.
///
/// The user config is a single JSON file that defines favorite repositories,
/// per-repo reviewer harness and roles, a global `people` map, and role
/// weights. It lives outside the skill:
///
/// 1. `--config <path>` if given,
/// 2. else `$REVIEW_TUNER_CONFIG`,
/// 3. else `~/.config/review-tuner/config.json`.
///
/// A missing config file is not an error: built-in defaults are used, so the
/// skill works on any repository with zero setup.
library;

import 'dart:convert';
import 'dart:io';

/// Exit code for a failed step or query (never reported as "no results").
const exitFailure = 1;

/// Exit code for invalid arguments.
const exitBadUsage = 2;

/// Default reviewer harness: the files Gemini Code Assist reads.
const defaultGuidance = ['.gemini/styleguide.md', '.gemini/config.yaml'];

const defaultBot = 'gemini-code-assist[bot]';

const defaultWeights = <String, double>{
  'maintainer': 1.0,
  'external': 0.5,
};

/// Roles inferred from GitHub's `authorAssociation` when no explicit role is
/// configured.
const associationRoles = <String, String>{
  'OWNER': 'maintainer',
  'MEMBER': 'maintainer',
  'COLLABORATOR': 'maintainer',
};

/// A reviewer harness: the prompt a simulated reviewer follows and the
/// guidance files (repo-relative) it is allowed to read.
final class Harness {
  const Harness({required this.prompt, required this.guidance});

  factory Harness.fromJson(Map<String, Object?>? json) => Harness(
        prompt: json?['prompt'] as String? ?? 'reviewer',
        guidance: [
          for (final g in json?['guidance'] as List? ?? defaultGuidance)
            g as String,
        ],
      );

  final String prompt;
  final List<String> guidance;

  Map<String, Object?> toJson() => {'prompt': prompt, 'guidance': guidance};
}

/// Settings for one target repository.
final class RepoConfig {
  RepoConfig({
    required this.slug,
    this.alias,
    this.bot = defaultBot,
    this.harness = const Harness(prompt: 'reviewer', guidance: defaultGuidance),
    this.automationAuthors = const [],
    this.roles = const {},
  });

  factory RepoConfig.fromJson(String slug, Map<String, Object?> json) =>
      RepoConfig(
        slug: slug,
        alias: json['alias'] as String?,
        bot: json['bot'] as String? ?? defaultBot,
        harness: Harness.fromJson(json['harness'] as Map<String, Object?>?),
        automationAuthors: [
          for (final a in json['automationAuthors'] as List? ?? const [])
            a as String,
        ],
        roles: {
          for (final e in (json['roles'] as Map? ?? const {}).entries)
            e.key as String: e.value as String,
        },
      );

  /// `owner/name`.
  final String slug;
  final String? alias;
  final String bot;
  final Harness harness;
  final List<String> automationAuthors;
  final Map<String, String> roles;

  String get owner => slug.split('/').first;
  String get name => slug.split('/').last;

  Map<String, Object?> toJson() => {
        'slug': slug,
        if (alias != null) 'alias': alias,
        'bot': bot,
        'harness': harness.toJson(),
        'automationAuthors': automationAuthors,
        'roles': roles,
      };
}

/// Optional bump for active external contributors: an `external` login that
/// authored at least [minPrsAuthored] PRs or wrote at least [minComments]
/// comments in a collection window gets role `frequent` and [weight].
final class FrequentContributor {
  const FrequentContributor({
    this.minPrsAuthored = 2,
    this.minComments = 5,
    this.weight = 0.75,
  });

  factory FrequentContributor.fromJson(Map<String, Object?> json) =>
      FrequentContributor(
        minPrsAuthored: json['minPrsAuthored'] as int? ?? 2,
        minComments: json['minComments'] as int? ?? 5,
        weight: (json['weight'] as num? ?? 0.75).toDouble(),
      );

  final int minPrsAuthored;
  final int minComments;
  final double weight;

  bool matches({required int authored, required int comments}) =>
      authored >= minPrsAuthored || comments >= minComments;
}

/// The user config.
final class Config {
  Config({
    required this.path,
    required this.dataDir,
    required this.weights,
    required this.people,
    required this.repos,
    this.frequentContributor,
  });

  /// Optional `frequentContributor` section; null when not configured.
  final FrequentContributor? frequentContributor;

  /// Path the config was loaded from (may not exist).
  final String path;

  /// Root for clones, corpora, and evals; `~` is expanded.
  final String dataDir;
  final Map<String, double> weights;
  final Map<String, String> people;
  final Map<String, RepoConfig> repos;

  /// Looks up a repo by `owner/name` or alias. Unknown repos get defaults so
  /// any repository can be targeted.
  RepoConfig repo(String slugOrAlias) {
    for (var r in repos.values) {
      if (r.slug == slugOrAlias || r.alias == slugOrAlias) return r;
    }
    if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(slugOrAlias)) {
      usageError('Unknown repo "$slugOrAlias": use owner/name or an alias.');
    }
    return RepoConfig(slug: slugOrAlias);
  }

  /// Role for [login] in [repo]: repo roles, then global people, then
  /// GitHub's [authorAssociation], else `external`. Bots are `bot`.
  String roleFor(RepoConfig repo, String login, {String? authorAssociation}) {
    if (login == repo.bot || login.endsWith('[bot]')) return 'bot';
    return repo.roles[login] ??
        people[login] ??
        associationRoles[authorAssociation] ??
        'external';
  }

  /// Weight for [role]; unknown roles fall back to `external`.
  double weightFor(String role) =>
      weights[role] ?? weights['external'] ?? defaultWeights['external']!;

  /// Per-repo data directory: `<dataDir>/<owner>/<name>`.
  String repoDir(RepoConfig repo) => '$dataDir/${repo.owner}/${repo.name}';
}

/// Expands a leading `~` using `$HOME`.
String expandHome(String path) {
  if (path == '~' || path.startsWith('~/')) {
    var home = Platform.environment['HOME'] ?? '';
    return '$home${path.substring(1)}';
  }
  return path;
}

/// Loads the user config (see library docs for resolution order).
Config loadConfig({String? path}) {
  var home = Platform.environment['HOME'] ?? '';
  var resolved = path ??
      Platform.environment['REVIEW_TUNER_CONFIG'] ??
      '$home/.config/review-tuner/config.json';
  resolved = expandHome(resolved);
  var json = <String, Object?>{};
  var file = File(resolved);
  if (file.existsSync()) {
    try {
      json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    } on FormatException catch (e) {
      stderr.writeln('Invalid config $resolved: ${e.message}');
      exit(exitFailure);
    }
  }
  return Config(
    path: resolved,
    dataDir: expandHome(json['dataDir'] as String? ?? '~/review-tuner-data'),
    weights: {
      ...defaultWeights,
      for (final e in (json['weights'] as Map? ?? const {}).entries)
        e.key as String: (e.value as num).toDouble(),
    },
    people: {
      for (final e in (json['people'] as Map? ?? const {}).entries)
        e.key as String: e.value as String,
    },
    repos: {
      for (final e in (json['repos'] as Map? ?? const {}).entries)
        e.key as String: RepoConfig.fromJson(
            e.key as String, e.value as Map<String, Object?>),
    },
    frequentContributor: switch (json['frequentContributor']) {
      Map<String, Object?> m => FrequentContributor.fromJson(m),
      _ => null,
    },
  );
}

/// Parses `--name value` options and `--flag` booleans (names in [flags]).
/// Anything not starting with `--` is positional; callers usually treat the
/// first positional as a subcommand.
({Map<String, String> options, List<String> positional}) parseArgs(
  List<String> argv, {
  Set<String> flags = const {},
}) {
  var options = <String, String>{};
  var positional = <String>[];
  for (var i = 0; i < argv.length; i++) {
    var arg = argv[i];
    if (!arg.startsWith('--')) {
      positional.add(arg);
      continue;
    }
    var name = arg.substring(2);
    if (flags.contains(name)) {
      options[name] = 'true';
    } else if (i + 1 < argv.length) {
      options[name] = argv[++i];
    } else {
      usageError('Missing value for $arg');
    }
  }
  return (options: options, positional: positional);
}

/// Prints [message] to stderr and exits with [exitBadUsage].
Never usageError(String message) {
  stderr.writeln(message);
  exit(exitBadUsage);
}

/// Reads and decodes a JSON file, exiting with [exitFailure] on error.
Object? readJson(String path) {
  var file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Missing file: $path');
    exit(exitFailure);
  }
  try {
    return jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    stderr.writeln('Invalid JSON in $path: ${e.message}');
    exit(exitFailure);
  }
}

/// Writes [value] as indented JSON, creating parent directories.
void writeJson(String path, Object? value) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(value)}\n');
}
