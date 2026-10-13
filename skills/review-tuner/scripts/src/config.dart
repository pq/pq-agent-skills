/// The review-tuner user config: favorite repositories, per-repo reviewer
/// harness and roles, a global `people` map, and role weights. It lives
/// outside the skill:
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

import 'cli.dart';

/// Default reviewer harness: the files Gemini Code Assist reads.
const defaultGuidance = ['.gemini/styleguide.md', '.gemini/config.yaml'];

const defaultBot = 'gemini-code-assist[bot]';

/// Weight of the `external` role (and of any role without a weight).
const defaultExternalWeight = 0.5;

const defaultWeights = <String, double>{
  'maintainer': 1.0,
  'external': defaultExternalWeight,
};

/// Roles inferred from GitHub's `authorAssociation` when no explicit role is
/// configured.
const associationRoles = <String, String>{
  'OWNER': 'maintainer',
  'MEMBER': 'maintainer',
  'COLLABORATOR': 'maintainer',
};

/// A well-formed `owner/name` repository slug.
final _slug = RegExp(r'^[\w.-]+/[\w.-]+$');

bool isSlug(String s) => _slug.hasMatch(s);

/// A reviewer harness: the guidance files (repo-relative) a simulated
/// reviewer is allowed to read.
final class Harness {
  const Harness({required this.guidance});

  factory Harness.fromJson(Map<String, Object?>? json) => Harness(
        guidance: [
          for (var g in json?['guidance'] as List? ?? defaultGuidance)
            g as String,
        ],
      );

  final List<String> guidance;
}

/// Settings for one target repository.
final class RepoConfig {
  RepoConfig({
    required this.slug,
    this.alias,
    this.bot = defaultBot,
    this.harness = const Harness(guidance: defaultGuidance),
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
          for (var a in json['automationAuthors'] as List? ?? const [])
            a as String,
        ],
        roles: {
          for (var e in (json['roles'] as Map? ?? const {}).entries)
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
}

/// The user config.
final class Config {
  Config({
    required this.dataDir,
    required this.weights,
    required this.people,
    required this.repos,
  });

  /// Root for clones, corpora, and evals; `~` is expanded.
  final String dataDir;
  final Map<String, double> weights;
  final Map<String, String> people;
  final Map<String, RepoConfig> repos;

  /// Looks up a repo by `owner/name` or alias. Unknown but well-formed slugs
  /// get defaults so any repository can be targeted; anything else is null
  /// (the caller decides whether that is a usage or a data error).
  RepoConfig? repo(String slugOrAlias) {
    for (var r in repos.values) {
      if (r.slug == slugOrAlias || r.alias == slugOrAlias) return r;
    }
    return isSlug(slugOrAlias) ? RepoConfig(slug: slugOrAlias) : null;
  }

  /// Role for [login] in [repo]: `bot` for the repo's bot or any `[bot]`
  /// login, then repo roles, global people, GitHub's [authorAssociation],
  /// else `external`.
  String roleFor(RepoConfig repo, String login, {String? authorAssociation}) {
    if (login == repo.bot || login.endsWith('[bot]')) return 'bot';
    return repo.roles[login] ??
        people[login] ??
        associationRoles[authorAssociation] ??
        'external';
  }

  /// True if [login] has an explicit role in [repo] or `people`.
  bool hasRole(RepoConfig repo, String login) =>
      repo.roles.containsKey(login) || people.containsKey(login);

  /// Weight for [role]; unknown roles get the `external` weight.
  double weightFor(String role) =>
      weights[role] ?? weights['external'] ?? defaultExternalWeight;

  /// Per-repo data directory: `<dataDir>/<owner>/<name>`.
  String repoDir(RepoConfig repo) => '$dataDir/${repo.owner}/${repo.name}';
}

/// `$HOME`; a [fail] if it is unset (paths would silently resolve to `/`).
String get _home =>
    Platform.environment['HOME'] ??
    fail('HOME is not set: pass --config and use absolute paths.');

/// Expands a leading `~` using `$HOME`.
String expandHome(String path) {
  if (path == '~' || path.startsWith('~/')) {
    return '$_home${path.substring(1)}';
  }
  return path;
}

/// Loads the user config (see library docs for resolution order).
Config loadConfig({String? path}) {
  var resolved = expandHome(path ??
      Platform.environment['REVIEW_TUNER_CONFIG'] ??
      '~/.config/review-tuner/config.json');
  var json = <String, Object?>{};
  var file = File(resolved);
  if (file.existsSync()) {
    try {
      json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    } on FormatException catch (e) {
      fail('Invalid config $resolved: ${e.message}');
    }
  }
  var repos = (json['repos'] as Map? ?? const {}).cast<String, Object?>();
  for (var slug in repos.keys) {
    if (!isSlug(slug)) fail('Config $resolved: repo "$slug" is not owner/name');
  }
  return Config(
    dataDir: expandHome(json['dataDir'] as String? ?? '~/review-tuner-data'),
    weights: {
      ...defaultWeights,
      for (var e in (json['weights'] as Map? ?? const {}).entries)
        e.key as String: (e.value as num).toDouble(),
    },
    people: {
      for (var e in (json['people'] as Map? ?? const {}).entries)
        e.key as String: e.value as String,
    },
    repos: {
      for (var MapEntry(:key, :value) in repos.entries)
        key: RepoConfig.fromJson(key, value as Map<String, Object?>),
    },
  );
}
