/// Collects pull request review activity for a repository over a date window
/// (the first phase of review-tuner), and digests a collected corpus into a
/// compact view for drafting guidance changes (propose mode).
///
/// `collect` (the default) fetches every PR closed in the window with
/// `gh api graphql` and records metadata, files, commits, inline comments
/// (with thread resolved/outdated state), review summaries, and issue
/// comments. Every participant gets a role and weight from the user config
/// (repo roles, then `people`, then GitHub's `authorAssociation`, else
/// `external`; see `src/config.dart`). Automation PRs are kept but marked
/// excluded. Writes the corpus as JSONL plus a `.stats.json` review-density
/// summary and the digest (`.digest.md`, `.digest.json`) next to it, and
/// prints the summary as markdown.
///
/// `digest` reads a corpus and builds, per PR, the human review comments and
/// the reviewer bot's inline comments with any human replies and the thread's
/// resolved state, so dismissed bot comments are visible. Excerpts are cut at
/// `--max-chars` (default 300); human replies in bot threads at 3x that,
/// since they carry the verdict. By default it writes
/// `<corpus base>.digest.md` and `.digest.json` next to the corpus and prints
/// a short summary; `--output-file` sets the JSON path (the markdown goes next
/// to it as `.md`); `--stdout` prints the full markdown instead of the summary.
///
/// `digest --select <regex>` counts the comments matching a theme
/// (case-insensitive, over full comment bodies): human comments by default,
/// or the reviewer bot's comments with `--bot` (also counting human replies and
/// resolved threads). `--path <regex>` filters by comment path. It prints
/// markdown (JSON too with `--output-file`) and never writes the default
/// digest files.
///
/// Usage:
///   dart collect.dart --repo <owner/name|alias>
///       [--since YYYY-MM-DD --until YYYY-MM-DD | --days N]
///       [--output-file <corpus.jsonl>] [--concurrency 4] [--max-chars 300]
///       [--config <path>]
///   dart collect.dart digest --corpus <corpus.jsonl> [--repo <owner/name>]
///       [--output-file <digest.json>] [--stdout] [--max-chars 300]
///       [--config <path>]
///   dart collect.dart digest --corpus <corpus.jsonl> --select <regex>
///       [--path <regex>] [--bot] [--output-file <select.json>]
///       [--repo <owner/name>] [--config <path>]
///
/// Exits 0 on success (including a `--select` with no matches), 1 if any
/// query or step failed (including a missing or invalid corpus), and 2 for
/// invalid arguments (including an invalid regex). A failed query is never
/// reported as "no review activity": failed PRs are listed in the summary and
/// the exit code is 1.
library;

import 'dart:convert';
import 'dart:io';

import 'src/config.dart';

/// Matches comments too short or formulaic to carry review guidance.
final _trivialComment = RegExp(
  r'^\s*(lgtm|sgtm|thanks!?|thank you!?|ty|done\.?|fixed\.?|nice!?|\+1|👍|🎉|'
  r'/gemini review|@gemini-code-assist review)[.! ]*$',
  caseSensitive: false,
);

/// GitHub search returns at most this many results per query.
const _searchCap = 1000;

/// Default characters of comment text kept in a digest (`--max-chars`).
const _defaultMaxChars = 300;

/// Characters of comment text shown per `--select` match.
const _selectExcerptLength = 160;

/// What kind of GitHub object a [Comment] came from.
enum CommentKind {
  /// An inline comment on a diff line, part of a review thread.
  inline,

  /// The body of a submitted review.
  review,

  /// A conversation comment on the PR.
  issue,
}

/// Thrown when a `gh` invocation fails after retries.
final class QueryException implements Exception {
  QueryException(this.command, this.message);

  final String command;
  final String message;

  @override
  String toString() => 'gh $command: $message';
}

// ---------------------------------------------------------------------------
// GitHub access
// ---------------------------------------------------------------------------

/// Runs `gh` with [args], retrying transient failures, and decodes JSON.
Future<Object?> gh(List<String> args) async {
  for (var attempt = 0;; attempt++) {
    var result = await Process.run('gh', args,
        stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.exitCode == 0) {
      var out = (result.stdout as String).trim();
      return out.isEmpty ? null : jsonDecode(out);
    }
    var err = (result.stderr as String).trim();
    var retryable = [
      'rate limit',
      'HTTP 5',
      'timeout',
      'something went wrong',
    ].any(err.toLowerCase().contains);
    if (retryable && attempt < 4) {
      await Future<void>.delayed(
          Duration(seconds: 5 * (attempt + 1) * (attempt + 1)));
      continue;
    }
    throw QueryException(args.take(2).join(' '), err);
  }
}

/// Runs a GraphQL [query] with string [vars] (`-f`) and int [ints] (`-F`),
/// returning `data`. GraphQL errors are failures, never empty results.
Future<Map<String, Object?>> graphql(
  String query, {
  Map<String, String> vars = const {},
  Map<String, int> ints = const {},
}) async {
  var response = await gh([
    'api',
    'graphql',
    '-f',
    'query=$query',
    for (var MapEntry(:key, :value) in vars.entries) ...['-f', '$key=$value'],
    for (var MapEntry(:key, :value) in ints.entries) ...['-F', '$key=$value'],
  ]) as Map<String, Object?>?;
  if (response?['errors'] case List errors when errors.isNotEmpty) {
    throw QueryException('api graphql', jsonEncode(errors));
  }
  if (response?['data'] case Map<String, Object?> data) return data;
  throw QueryException('api graphql', 'response has no data');
}

const _searchQuery = r'''
query($q: String!, $cursor: String) {
  search(query: $q, type: ISSUE, first: 100, after: $cursor) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest { number } }
  }
}''';

/// Lists the numbers of PRs in [repo] closed within the window (inclusive).
Future<List<int>> listClosedPrs(String repo, String since, String until) async {
  var numbers = <int>[];
  String? cursor;
  var total = 0;
  do {
    var data = await graphql(_searchQuery, vars: {
      'q': 'repo:$repo is:pr is:closed closed:$since..$until',
      if (cursor != null) 'cursor': cursor,
    });
    var search = data['search'] as Map<String, Object?>;
    total = search['issueCount'] as int;
    for (var node in (search['nodes'] as List).cast<Map>()) {
      if (node['number'] case int n) numbers.add(n);
    }
    var page = search['pageInfo'] as Map;
    cursor = page['hasNextPage'] == true ? page['endCursor'] as String : null;
  } while (cursor != null);
  if (total > numbers.length) {
    throw QueryException(
      'api graphql',
      'search matched $total PRs but returned ${numbers.length} (GitHub caps '
          'search at $_searchCap); use a shorter window',
    );
  }
  return numbers..sort();
}

const _actor = '__typename login';
const _reactionFields = 'reactionGroups { content reactors { totalCount } }';

const _prQuery = '''
query(\$owner: String!, \$name: String!, \$number: Int!) {
  repository(owner: \$owner, name: \$name) {
    pullRequest(number: \$number) {
      number title url state isDraft createdAt closedAt mergedAt
      baseRefName baseRefOid headRefOid
      author { $_actor } authorAssociation
      labels(first: 50) { nodes { name } }
      files(first: 100) {
        pageInfo { hasNextPage }
        nodes { path additions deletions changeType }
      }
      commits(first: 100) {
        pageInfo { hasNextPage }
        nodes { commit { oid committedDate messageHeadline } }
      }
      reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          isResolved isOutdated
          comments(first: 100) {
            pageInfo { hasNextPage }
            nodes {
              databaseId author { $_actor } authorAssociation body createdAt
              path line originalLine commit { oid }
              replyTo { databaseId } pullRequestReview { databaseId }
              $_reactionFields
            }
          }
        }
      }
      reviews(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          databaseId author { $_actor } authorAssociation body state
          submittedAt commit { oid }
        }
      }
      comments(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          databaseId author { $_actor } authorAssociation body createdAt
          $_reactionFields
        }
      }
    }
  }
}''';

/// Fetches one PR with all of its review activity.
Future<Map<String, Object?>> fetchPr(RepoConfig repo, int number) async {
  var data = await graphql(
    _prQuery,
    vars: {'owner': repo.owner, 'name': repo.name},
    ints: {'number': number},
  );
  var pr = (data['repository'] as Map?)?['pullRequest'];
  if (pr is! Map<String, Object?>) {
    throw QueryException('api graphql', 'PR #$number not found');
  }
  return pr;
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// Resolves roles and weights, including the optional frequent-contributor
/// bump for [frequent] logins.
final class Roles {
  Roles(this.config, this.repo, [this.frequent = const {}]);

  final Config config;
  final RepoConfig repo;
  final Set<String> frequent;

  String of(String login, String? association) {
    var role = config.roleFor(repo, login, authorAssociation: association);
    return role == 'external' && frequent.contains(login) ? 'frequent' : role;
  }

  double weight(String role) => role == 'frequent'
      ? config.frequentContributor!.weight
      : config.weightFor(role);

  /// True if [login] has an explicit role in the repo or `people` config.
  bool isConfigured(String login) =>
      repo.roles.containsKey(login) || config.people.containsKey(login);
}

/// A single human or bot comment on a pull request.
final class Comment {
  Comment({
    required this.kind,
    required this.id,
    required this.author,
    required this.association,
    required this.isBot,
    required this.isPrAuthor,
    required this.body,
    required this.createdAt,
    this.path,
    this.line,
    this.commitId,
    this.inReplyTo,
    this.threadId,
    this.reviewId,
    this.reviewState,
    this.resolved,
    this.outdated,
    this.reactions = const {},
  });

  final CommentKind kind;
  final int id;
  final String author;
  final String? association;
  final bool isBot;
  final bool isPrAuthor;
  final String body;
  final String createdAt;
  final String? path;
  final int? line;
  final String? commitId;
  final int? inReplyTo;

  /// Id of the first comment in this comment's review thread (inline only).
  final int? threadId;
  final int? reviewId;
  final String? reviewState;
  final bool? resolved;
  final bool? outdated;
  final Map<String, int> reactions;

  bool get isHuman => !isBot;

  /// Heuristic: long enough and not formulaic. Used for stats and digests.
  bool get isSubstantive =>
      body.trim().length >= 20 && !_trivialComment.hasMatch(body);

  Map<String, Object?> toJson(Roles roles) {
    var role = roles.of(author, association);
    return {
      'kind': kind.name,
      'id': id,
      'author': author,
      'role': role,
      'weight': roles.weight(role),
      if (association != null) 'authorAssociation': association,
      'isPrAuthor': isPrAuthor,
      'body': body,
      'createdAt': createdAt,
      if (path != null) 'path': path,
      if (line != null) 'line': line,
      if (commitId != null) 'commitId': commitId,
      if (inReplyTo != null) 'inReplyTo': inReplyTo,
      if (threadId != null) 'threadId': threadId,
      if (reviewId != null) 'reviewId': reviewId,
      if (reviewState != null) 'reviewState': reviewState,
      if (resolved != null) 'threadResolved': resolved,
      if (outdated != null) 'threadOutdated': outdated,
      if (reactions.isNotEmpty) 'reactions': reactions,
    };
  }
}

/// A pull request with all of its collected review activity.
final class PullRequest {
  PullRequest({
    required this.meta,
    required this.author,
    required this.association,
    required this.comments,
    required this.commits,
    required this.truncated,
    this.excludedReason,
  });

  /// Parses a GraphQL `pullRequest` node.
  factory PullRequest.fromGraphql(Map<String, Object?> node, RepoConfig repo) {
    var author = _login(node['author']);
    var parser = _CommentParser(repo, author);
    var automation = {for (var a in repo.automationAuthors) a.toLowerCase()};
    return PullRequest(
      meta: _meta(node),
      author: author,
      association: node['authorAssociation'] as String?,
      comments: parser.parse(node),
      commits: [
        for (var c in _nodes(node['commits']))
          {
            'sha': (c['commit'] as Map)['oid'],
            'date': (c['commit'] as Map)['committedDate'],
            'message': (c['commit'] as Map)['messageHeadline'],
          },
      ],
      truncated: [
        for (var key in ['files', 'commits', 'reviewThreads', 'reviews'])
          if (_hasNextPage(node[key])) key,
        if (_hasNextPage(node['comments'])) 'issueComments',
        if (_nodes(node['reviewThreads'])
            .any((t) => _hasNextPage(t['comments'])))
          'threadComments',
      ],
      excludedReason:
          _isBot(repo, author) || automation.contains(author.toLowerCase())
              ? 'automation-author'
              : null,
    );
  }

  final Map<String, Object?> meta;
  final String author;
  final String? association;
  final List<Comment> comments;
  final List<Map<String, Object?>> commits;

  /// Connections that had more than one page (data beyond it is missing).
  final List<String> truncated;
  final String? excludedReason;

  int get number => meta['number'] as int;
  bool get merged => meta['mergedAt'] != null;

  /// Human comments not written by the PR author.
  Iterable<Comment> get reviewerComments =>
      comments.where((c) => c.isHuman && !c.isPrAuthor);

  /// Timestamp of the first human, non-author review activity, if any.
  String? get firstHumanReviewAt {
    var times = reviewerComments.map((c) => c.createdAt).toList()..sort();
    return times.isEmpty ? null : times.first;
  }

  /// Commits made after the first human review: a proxy for review rounds.
  /// Undercounts when branches are force-pushed.
  int get postReviewCommits {
    var first = firstHumanReviewAt;
    if (first == null) return 0;
    return commits.where((c) {
      var date = c['date'] as String?;
      return date != null && date.compareTo(first) > 0;
    }).length;
  }

  Map<String, Object?> toJson(Roles roles) {
    var role = roles.of(author, association);
    return {
      ...meta,
      'author': author,
      'authorRole': role,
      'authorWeight': roles.weight(role),
      if (association != null) 'authorAssociation': association,
      'outcome': merged ? 'merged' : 'closed-unmerged',
      if (excludedReason != null) 'excludedReason': excludedReason,
      'threadsTruncated': truncated.contains('reviewThreads') ||
          truncated.contains('threadComments'),
      if (truncated.isNotEmpty) 'truncated': truncated,
      'postReviewCommits': postReviewCommits,
      'commits': commits,
      'comments': [for (var c in comments) c.toJson(roles)],
    };
  }
}

/// Turns the comment connections of a GraphQL PR node into [Comment]s.
final class _CommentParser {
  _CommentParser(this.repo, this.prAuthor);

  final RepoConfig repo;
  final String prAuthor;

  List<Comment> parse(Map<String, Object?> node) => [
        for (var thread in _nodes(node['reviewThreads'])) ..._thread(thread),
        for (var r in _nodes(node['reviews']))
          if (r['state'] != 'PENDING' &&
              ((r['body'] as String? ?? '').trim().isNotEmpty ||
                  r['state'] == 'CHANGES_REQUESTED' ||
                  r['state'] == 'APPROVED'))
            _comment(CommentKind.review, r,
                createdAt: r['submittedAt'],
                reviewState: r['state'] as String?),
        for (var c in _nodes(node['comments']))
          _comment(CommentKind.issue, c, createdAt: c['createdAt']),
      ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  Iterable<Comment> _thread(Map<String, Object?> thread) {
    var comments = _nodes(thread['comments']);
    var rootId = comments.firstOrNull?['databaseId'] as int?;
    return [
      for (var c in comments)
        _comment(
          CommentKind.inline,
          c,
          createdAt: c['createdAt'],
          threadId: rootId,
          resolved: thread['isResolved'] as bool?,
          outdated: thread['isOutdated'] as bool?,
        ),
    ];
  }

  Comment _comment(
    CommentKind kind,
    Map<String, Object?> j, {
    required Object? createdAt,
    String? reviewState,
    int? threadId,
    bool? resolved,
    bool? outdated,
  }) {
    var login = _login(j['author']);
    return Comment(
      kind: kind,
      id: j['databaseId'] as int,
      author: login,
      association: j['authorAssociation'] as String?,
      isBot: _isBot(repo, login),
      isPrAuthor: login.toLowerCase() == prAuthor.toLowerCase(),
      body: j['body'] as String? ?? '',
      createdAt: createdAt as String? ?? '',
      path: j['path'] as String?,
      line: (j['line'] ?? j['originalLine']) as int?,
      commitId: (j['commit'] as Map?)?['oid'] as String?,
      inReplyTo: (j['replyTo'] as Map?)?['databaseId'] as int?,
      threadId: threadId,
      reviewId: (j['pullRequestReview'] as Map?)?['databaseId'] as int?,
      reviewState: reviewState,
      resolved: resolved,
      outdated: outdated,
      reactions: _reactions(j['reactionGroups']),
    );
  }
}

Map<String, Object?> _meta(Map<String, Object?> node) => {
      for (var key in [
        'number',
        'title',
        'url',
        'state',
        'isDraft',
        'createdAt',
        'closedAt',
        'mergedAt',
        'baseRefName',
        'baseRefOid',
        'headRefOid',
      ])
        key: node[key],
      'labels': [for (var l in _nodes(node['labels'])) l['name']],
      'files': _nodes(node['files']),
    };

List<Map<String, Object?>> _nodes(Object? connection) => [
      for (var n in (connection as Map?)?['nodes'] as List? ?? const [])
        if (n is Map<String, Object?>) n,
    ];

bool _hasNextPage(Object? connection) =>
    ((connection as Map?)?['pageInfo'] as Map?)?['hasNextPage'] == true;

/// GraphQL reports bot logins without the `[bot]` suffix REST and the config
/// use; this restores it.
String _login(Object? actor) {
  if (actor is! Map) return 'ghost';
  var login = actor['login'] as String? ?? 'ghost';
  var isBot = actor['__typename'] == 'Bot' && !login.endsWith('[bot]');
  return isBot ? '$login[bot]' : login;
}

bool _isBot(RepoConfig repo, String login) =>
    login == repo.bot || login.endsWith('[bot]');

const _reactionNames = {
  'THUMBS_UP': '+1',
  'THUMBS_DOWN': '-1',
  'LAUGH': 'laugh',
  'HOORAY': 'hooray',
  'CONFUSED': 'confused',
  'HEART': 'heart',
  'ROCKET': 'rocket',
  'EYES': 'eyes',
};

/// Reaction counts keyed by REST names (`+1`, `heart`, ...).
Map<String, int> _reactions(Object? groups) => {
      for (var g in (groups as List? ?? const []).cast<Map>())
        if (((g['reactors'] as Map)['totalCount'] as int) > 0)
          _reactionNames[g['content']] ??
                  (g['content'] as String).toLowerCase():
              (g['reactors'] as Map)['totalCount'] as int,
    };

// ---------------------------------------------------------------------------
// Collect
// ---------------------------------------------------------------------------

typedef Participation = Map<String, ({int authored, int comments})>;

/// PRs authored and human comments written per login, over non-excluded PRs.
Participation participation(List<PullRequest> prs) {
  var result = <String, ({int authored, int comments})>{};
  for (var pr in prs.where((p) => p.excludedReason == null)) {
    var a = result[pr.author] ?? (authored: 0, comments: 0);
    result[pr.author] = (authored: a.authored + 1, comments: a.comments);
    for (var c in pr.comments.where((c) => c.isHuman)) {
      var p = result[c.author] ?? (authored: 0, comments: 0);
      result[c.author] = (authored: p.authored, comments: p.comments + 1);
    }
  }
  return result;
}

/// Logins that qualify for the frequent-contributor bump, if configured.
Set<String> frequentLogins(Config config, Participation counts) {
  var rule = config.frequentContributor;
  if (rule == null) return const {};
  return {
    for (var MapEntry(key: login, :value) in counts.entries)
      if (rule.matches(authored: value.authored, comments: value.comments))
        login,
  };
}

/// Runs [task] over [items] with at most [concurrency] in flight.
Future<void> pooled<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T) task,
) async {
  var next = 0;
  Future<void> worker() async {
    while (next < items.length) {
      await task(items[next++]);
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
}

/// Resolves the collection window from `--since/--until` or `--days`.
({String since, String until}) parseWindow(Map<String, String> options) {
  var since = options['since'];
  var until = options['until'];
  if (since != null || until != null) {
    if (since == null || until == null) {
      usageError('--since and --until must be given together.');
    }
    var date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (!date.hasMatch(since) ||
        !date.hasMatch(until) ||
        DateTime.tryParse(since) == null ||
        DateTime.tryParse(until) == null) {
      usageError('--since/--until must be YYYY-MM-DD.');
    }
    if (since.compareTo(until) > 0) usageError('--since is after --until.');
    return (since: since, until: until);
  }
  var days = int.tryParse(options['days'] ?? '90');
  if (days == null || days < 1) {
    usageError('--days must be a positive integer.');
  }
  var today = DateTime.now().toUtc();
  String day(DateTime d) => d.toIso8601String().substring(0, 10);
  return (
    since: day(today.subtract(Duration(days: days))),
    until: day(today),
  );
}

Future<void> runCollect(Map<String, String> options) async {
  var slug = options['repo'] ?? usageError('Missing --repo <owner/name>.');
  var config = loadConfig(path: options['config']);
  var repo = config.repo(slug);
  var window = parseWindow(options);
  var concurrency = int.tryParse(options['concurrency'] ?? '4') ?? 0;
  if (concurrency < 1) usageError('--concurrency must be a positive integer.');
  var output = options['output-file'] ??
      '${config.repoDir(repo)}/corpus/${window.since}_${window.until}.jsonl';
  var statsPath = '${_base(output)}.stats.json';
  var maxChars = _maxChars(options);

  List<int> numbers;
  try {
    numbers = await listClosedPrs(repo.slug, window.since, window.until);
  } on QueryException catch (e) {
    stderr.writeln('Failed to list PRs: $e');
    exit(exitFailure);
  }
  stderr.writeln('Listed ${numbers.length} PRs; collecting activity...');

  var prs = <PullRequest>[];
  var failures = <int, String>{};
  var done = 0;
  await pooled(numbers, concurrency, (number) async {
    try {
      prs.add(PullRequest.fromGraphql(await fetchPr(repo, number), repo));
    } on Object catch (e) {
      failures[number] = '$e';
    }
    if (++done % 10 == 0) stderr.writeln('  $done/${numbers.length}');
  });
  prs.sort((a, b) => a.number.compareTo(b.number));

  var counts = participation(prs);
  var roles = Roles(config, repo, frequentLogins(config, counts));
  var corpus = [for (var p in prs) p.toJson(roles)];
  File(output)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync([for (var p in corpus) '${jsonEncode(p)}\n'].join());
  var digest = buildDigest(corpus, repo, output, maxChars);
  var digestPaths = _defaultDigestPaths(output);
  writeDigest(digest, digestPaths.json, digestPaths.md);
  var stats = {
    ...computeStats(prs, roles, counts, failures, window),
    'humanCommentsTotal': digest['humanCommentsTotal'],
    'humanCommentsWeighted': digest['humanCommentsWeighted'],
  };
  writeJson(statsPath, stats);
  stdout
    ..write(renderStats(stats))
    ..writeln()
    ..writeln('Wrote:')
    ..writeln('- $output')
    ..writeln('- $statsPath')
    ..writeln('- ${digestPaths.md}')
    ..writeln('- ${digestPaths.json}');
  if (failures.isNotEmpty) exit(exitFailure);
}

/// Density statistics over the non-excluded PRs.
Map<String, Object?> computeStats(
  List<PullRequest> prs,
  Roles roles,
  Participation counts,
  Map<int, String> failures,
  ({String since, String until}) window,
) {
  var considered = prs.where((p) => p.excludedReason == null).toList();
  var bot = roles.repo.bot;
  var botInline = [
    for (var p in considered)
      ...p.comments
          .where((c) => c.author == bot && c.kind == CommentKind.inline),
  ];
  var botIds = {for (var c in botInline) c.id};
  var rounds = [
    for (var p in considered)
      if (p.firstHumanReviewAt != null) p.postReviewCommits,
  ]..sort();
  return {
    'repo': roles.repo.slug,
    'window': {'since': window.since, 'until': window.until},
    'collectedAt': DateTime.now().toUtc().toIso8601String(),
    'prsTotal': prs.length + failures.length,
    'prsCollected': prs.length,
    'prsFailed': failures.length,
    'prsExcludedAutomation': prs.length - considered.length,
    'prsConsidered': considered.length,
    'merged': considered.where((p) => p.merged).length,
    'closedUnmerged': considered.where((p) => !p.merged).length,
    'prsByAuthorRole': _tally([
      for (var p in considered) roles.of(p.author, p.association),
    ]),
    'prsWithHumanInlineComments': considered
        .where(
            (p) => p.reviewerComments.any((c) => c.kind == CommentKind.inline))
        .length,
    'prsWithSubstantiveHumanComments': considered
        .where((p) => p.reviewerComments.any((c) => c.isSubstantive))
        .length,
    ..._reviewerStats(considered, roles),
    'postReviewCommits': {
      'prsReviewed': rounds.length,
      'median': rounds.isEmpty ? 0 : rounds[rounds.length ~/ 2],
      'max': rounds.isEmpty ? 0 : rounds.last,
    },
    'bot': {
      'login': bot,
      'prsWithBotActivity': considered
          .where((p) => p.comments.any((c) => c.author == bot))
          .length,
      'botInlineComments': botInline.length,
      'botInlineResolved': botInline.where((c) => c.resolved == true).length,
      'humanRepliesToBotInline': [
        for (var p in considered)
          ...p.comments.where((c) =>
              c.isHuman && c.threadId != c.id && botIds.contains(c.threadId)),
      ].length,
    },
    'truncatedPrs': {
      for (var p in prs)
        if (p.truncated.isNotEmpty) '${p.number}': p.truncated,
    },
    'unconfiguredFrequentParticipants': _unconfigured(counts, roles),
    'failedPrs': {
      for (var MapEntry(:key, :value) in failures.entries) '$key': value,
    },
  };
}

/// Substantive reviewer comments by role and by reviewer.
Map<String, Object?> _reviewerStats(List<PullRequest> prs, Roles roles) {
  var byRole = <String, int>{};
  var byReviewer = <String, Map<String, Object?>>{};
  for (var pr in prs) {
    var seen = <String>{};
    for (var c in pr.reviewerComments.where((c) => c.isSubstantive)) {
      var role = roles.of(c.author, c.association);
      byRole.update(role, (v) => v + 1, ifAbsent: () => 1);
      var r = byReviewer.putIfAbsent(
          c.author,
          () => {
                'role': role,
                'weight': roles.weight(role),
                'substantiveComments': 0,
                'prs': 0,
              });
      r['substantiveComments'] = (r['substantiveComments'] as int) + 1;
      if (seen.add(c.author)) r['prs'] = (r['prs'] as int) + 1;
    }
  }
  return {
    'substantiveReviewerCommentsByRole': byRole,
    'reviewers': byReviewer,
  };
}

/// Active humans with no explicit role in the config (role came from
/// GitHub's association or the frequent bump): candidates for the config.
List<Map<String, Object?>> _unconfigured(Participation counts, Roles roles) => [
      for (var MapEntry(key: login, :value) in counts.entries)
        if (!roles.isConfigured(login) &&
            !_isBot(roles.repo, login) &&
            (value.authored >= 2 || value.comments >= 5))
          {
            'login': login,
            'authored': value.authored,
            'comments': value.comments,
          },
    ]..sort((a, b) => (b['comments'] as int).compareTo(a['comments'] as int));

Map<String, int> _tally(Iterable<String> values) {
  var counts = <String, int>{};
  for (var v in values) {
    counts.update(v, (n) => n + 1, ifAbsent: () => 1);
  }
  return counts;
}

String renderStats(Map<String, Object?> s) {
  var b = StringBuffer();
  var window = s['window'] as Map;
  b
    ..writeln('# Review density: ${s['repo']}')
    ..writeln()
    ..writeln(
        'Window: PRs closed ${window['since']} → ${window['until']} (UTC)')
    ..writeln()
    ..writeln('| Metric | Value |')
    ..writeln('|---|---|');
  for (var key in [
    'prsTotal',
    'prsFailed',
    'prsExcludedAutomation',
    'prsConsidered',
    'merged',
    'closedUnmerged',
    'prsWithHumanInlineComments',
    'prsWithSubstantiveHumanComments',
    'humanCommentsTotal',
    'humanCommentsWeighted',
  ]) {
    var v = s[key];
    b.writeln('| $key | ${v is double ? v.toStringAsFixed(1) : v} |');
  }
  for (var MapEntry(:key, :value) in (s['bot'] as Map).entries) {
    b.writeln('| bot.$key | $value |');
  }
  var rounds = s['postReviewCommits'] as Map;
  b.writeln('| postReviewCommits (median / max over ${rounds['prsReviewed']} '
      'PRs) | ${rounds['median']} / ${rounds['max']} |');
  _table(b, 'PRs by author role', [
    'Role',
    'PRs'
  ], [
    for (var MapEntry(:key, :value) in (s['prsByAuthorRole'] as Map).entries)
      [key, value],
  ]);
  var reviewers = (s['reviewers'] as Map).entries.toList()
    ..sort((a, b) => ((b.value as Map)['substantiveComments'] as int)
        .compareTo((a.value as Map)['substantiveComments'] as int));
  _table(b, 'Substantive reviewer comments (non-author humans)', [
    'Reviewer',
    'Role',
    'Weight',
    'Comments',
    'PRs'
  ], [
    for (var MapEntry(:key, :value) in reviewers)
      [
        key,
        for (var f in ['role', 'weight', 'substantiveComments', 'prs'])
          (value as Map)[f],
      ],
  ]);
  _list(b, 'Unconfigured frequent participants', [
    for (var u in (s['unconfiguredFrequentParticipants'] as List).cast<Map>())
      '${u['login']}: authored ${u['authored']}, comments ${u['comments']}',
  ]);
  _list(b, 'Truncated PRs (first page only)', [
    for (var MapEntry(:key, :value) in (s['truncatedPrs'] as Map).entries)
      '#$key: ${(value as List).join(', ')}',
  ]);
  _list(b, 'FAILED queries (data incomplete)', [
    for (var MapEntry(:key, :value) in (s['failedPrs'] as Map).entries)
      '#$key: $value',
  ]);
  return b.toString();
}

void _table(StringBuffer b, String title, List<String> header,
    List<List<Object?>> rows) {
  b
    ..writeln()
    ..writeln('## $title')
    ..writeln()
    ..writeln('| ${header.join(' | ')} |')
    ..writeln('|${'---|' * header.length}');
  for (var row in rows) {
    b.writeln('| ${row.join(' | ')} |');
  }
}

void _list(StringBuffer b, String title, List<String> items) {
  if (items.isEmpty) return;
  b
    ..writeln()
    ..writeln('## $title')
    ..writeln();
  for (var item in items) {
    b.writeln('- $item');
  }
}

// ---------------------------------------------------------------------------
// Digest
// ---------------------------------------------------------------------------

/// Collapses whitespace, turns badge images (`![high](...)`) into `[high]`,
/// and truncates to [max] characters.
String excerpt(String body, int max) {
  var text = body
      .replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => '[${m[1]}]')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return text.length <= max ? text : '${text.substring(0, max)}…';
}

/// [path] without a trailing `.jsonl` or `.json`.
String _base(String path) => path.replaceFirst(RegExp(r'\.jsonl?$'), '');

/// Where `collect` and a plain `digest` write the digest for [corpusPath].
({String md, String json}) _defaultDigestPaths(String corpusPath) => (
      md: '${_base(corpusPath)}.digest.md',
      json: '${_base(corpusPath)}.digest.json',
    );

int _maxChars(Map<String, String> options) {
  var n = int.tryParse(options['max-chars'] ?? '$_defaultMaxChars');
  if (n == null || n < 1) usageError('--max-chars must be a positive integer.');
  return n;
}

RegExp _regex(String option, String pattern) {
  try {
    return RegExp(pattern, caseSensitive: false);
  } on FormatException catch (e) {
    usageError('Invalid --$option regex: ${e.message}');
  }
}

List<Map<String, Object?>> readCorpus(String path) {
  var file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Missing corpus: $path');
    exit(exitFailure);
  }
  try {
    return [
      for (var line in file.readAsLinesSync())
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
    ];
  } on FormatException catch (e) {
    stderr.writeln('Invalid corpus line in $path: ${e.message}');
    exit(exitFailure);
  }
}

/// `owner/name` from a PR URL such as `https://github.com/o/n/pull/1`.
String? _slugFromUrl(Object? url) =>
    RegExp(r'github\.com/([^/]+/[^/]+)/pull/').firstMatch('$url')?[1];

/// Link to comment [c] on [pr], or null if the corpus has no PR URL.
String? _commentUrl(Map pr, Map c) {
  if (pr['url'] case String url) {
    return switch (c['kind']) {
      'inline' => '$url#discussion_r${c['id']}',
      'review' => '$url#pullrequestreview-${c['id']}',
      _ => '$url#issuecomment-${c['id']}',
    };
  }
  return null;
}

Map<String, Object?> _digestComment(Map c, int max) => {
      'author': c['author'],
      'role': c['role'],
      'weight': c['weight'],
      if (c['isPrAuthor'] == true) 'isPrAuthor': true,
      'kind': c['kind'],
      if (c['path'] != null) 'path': c['path'],
      if (c['line'] != null) 'line': c['line'],
      'text': excerpt(c['body'] as String? ?? '', max),
    };

/// Digest of one PR, or null if it has nothing worth showing. Human replies
/// in bot threads keep 3x [maxChars], since they carry the verdict.
Map<String, Object?>? digestPr(
    Map<String, Object?> pr, String bot, int maxChars) {
  var comments = (pr['comments'] as List).cast<Map>();
  var botRoots = {
    for (var c in comments)
      if (c['author'] == bot &&
          c['kind'] == 'inline' &&
          (c['threadId'] ?? c['id']) == c['id'])
        c['id'],
  };
  var human = [
    for (var c in comments)
      if (c['role'] != 'bot' &&
          !botRoots.contains(c['threadId']) &&
          (c['body'] as String? ?? '').trim().length >= 20 &&
          !_trivialComment.hasMatch(c['body'] as String))
        _digestComment(c, maxChars),
  ];
  var botThreads = [
    for (var root in comments.where((c) => botRoots.contains(c['id'])))
      {
        'path': root['path'],
        'line': root['line'],
        'resolved': root['threadResolved'],
        'outdated': root['threadOutdated'],
        'text': excerpt(root['body'] as String? ?? '', maxChars),
        'replies': [
          for (var c in comments)
            if (c['threadId'] == root['id'] &&
                c['id'] != root['id'] &&
                c['role'] != 'bot')
              _digestComment(c, maxChars * 3),
        ],
      },
  ];
  if (human.isEmpty && botThreads.isEmpty) return null;
  return {
    'number': pr['number'],
    'title': pr['title'],
    'author': pr['author'],
    'authorRole': pr['authorRole'],
    'outcome': pr['outcome'],
    'human': human,
    'bot': botThreads,
  };
}

/// Totals by role and most-commented paths over the digested PRs.
Map<String, Object?> digestTotals(List<Map<String, Object?>> prs) {
  var byRole = <String, ({int comments, double weight})>{};
  var paths = <String, ({int human, int bot})>{};
  void path(Object? p, {required bool isBot}) {
    if (p is! String) return;
    var v = paths[p] ?? (human: 0, bot: 0);
    paths[p] = isBot
        ? (human: v.human, bot: v.bot + 1)
        : (human: v.human + 1, bot: v.bot);
  }

  var humans = [
    for (var pr in prs) ...[
      ...(pr['human'] as List).cast<Map>(),
      for (var t in (pr['bot'] as List).cast<Map>())
        ...(t['replies'] as List).cast<Map>(),
    ],
  ];
  var weighted = 0.0;
  for (var c in humans) {
    var weight = (c['weight'] as num? ?? 0).toDouble();
    weighted += weight;
    var r = byRole[c['role']] ?? (comments: 0, weight: 0.0);
    byRole[c['role'] as String] =
        (comments: r.comments + 1, weight: r.weight + weight);
    if (c['kind'] == 'inline') path(c['path'], isBot: false);
  }
  var threads = [for (var pr in prs) ...(pr['bot'] as List).cast<Map>()];
  for (var t in threads) {
    path(t['path'], isBot: true);
  }
  var topPaths = paths.entries.toList()
    ..sort((a, b) =>
        (b.value.human + b.value.bot).compareTo(a.value.human + a.value.bot));
  return {
    'humanCommentsTotal': humans.length,
    'humanCommentsWeighted': weighted,
    'humanCommentsByRole': {
      for (var MapEntry(:key, :value) in byRole.entries)
        key: {'comments': value.comments, 'weight': value.weight},
    },
    'botThreads': threads.length,
    'botThreadsResolved': threads.where((t) => t['resolved'] == true).length,
    'botThreadsWithHumanReply':
        threads.where((t) => (t['replies'] as List).isNotEmpty).length,
    'topPaths': [
      for (var e in topPaths.take(15))
        {'path': e.key, 'human': e.value.human, 'bot': e.value.bot},
    ],
  };
}

/// The digest of [corpus] (as written by `collect`).
Map<String, Object?> buildDigest(List<Map<String, Object?>> corpus,
    RepoConfig repo, String corpusPath, int maxChars) {
  var considered = corpus.where((p) => p['excludedReason'] == null).toList();
  var prs = [
    for (var pr in considered)
      if (digestPr(pr, repo.bot, maxChars) case var d?) d,
  ];
  return {
    'repo': repo.slug,
    'corpus': corpusPath,
    'bot': repo.bot,
    'maxChars': maxChars,
    'prsInCorpus': corpus.length,
    'prsSkippedAutomation': corpus.length - considered.length,
    'prsWithActivity': prs.length,
    ...digestTotals(prs),
    'prs': prs,
  };
}

/// Writes [digest] as JSON to [jsonPath] and markdown to [mdPath].
void writeDigest(Map<String, Object?> digest, String jsonPath, String mdPath) {
  writeJson(jsonPath, digest);
  File(mdPath)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(renderDigest(digest));
}

void runDigest(Map<String, String> options) {
  var corpusPath =
      options['corpus'] ?? usageError('Missing --corpus <corpus.jsonl>.');
  var select = options['select'];
  if (select == null) {
    for (var flag in ['path', 'bot']) {
      if (options.containsKey(flag)) usageError('--$flag requires --select.');
    }
  }
  var selectRegex = select == null ? null : _regex('select', select);
  var pathRegex =
      options['path'] == null ? null : _regex('path', options['path']!);
  var maxChars = _maxChars(options);
  var corpus = readCorpus(corpusPath);
  var slug = options['repo'] ??
      _slugFromUrl(corpus.firstOrNull?['url']) ??
      usageError('Cannot infer the repo from the corpus; pass --repo.');
  var repo = loadConfig(path: options['config']).repo(slug);

  if (selectRegex != null) {
    var result = selectComments(corpus, selectRegex, pathRegex,
        bot: options.containsKey('bot') ? repo.bot : null);
    result = {'repo': repo.slug, 'corpus': corpusPath, ...result};
    if (options['output-file'] case var path?) writeJson(path, result);
    stdout.write(renderSelect(result));
    return;
  }

  var digest = buildDigest(corpus, repo, corpusPath, maxChars);
  var paths = switch (options['output-file']) {
    var path? => (md: '${_base(path)}.md', json: path),
    null => _defaultDigestPaths(corpusPath),
  };
  writeDigest(digest, paths.json, paths.md);
  if (options.containsKey('stdout')) {
    stdout.write(renderDigest(digest));
  } else {
    stdout
      ..writeln(_digestHeader(digest))
      ..writeln()
      ..writeln('Wrote:')
      ..writeln('- ${paths.md}')
      ..writeln('- ${paths.json}');
  }
}

/// Comments in non-automation PRs whose full body matches [text] (and whose
/// path matches [path], if given): human comments, or those by the reviewer
/// [bot] login if given (other bots, such as CLA or merge bots, are skipped).
Map<String, Object?> selectComments(
    List<Map<String, Object?>> corpus, RegExp text, RegExp? path,
    {String? bot}) {
  var matches = <Map<String, Object?>>[];
  for (var pr in corpus.where((p) => p['excludedReason'] == null)) {
    var comments = (pr['comments'] as List).cast<Map>();
    for (var c in comments) {
      if (bot == null ? c['role'] == 'bot' : c['author'] != bot) continue;
      if (!text.hasMatch(c['body'] as String? ?? '')) continue;
      if (path != null && !path.hasMatch(c['path'] as String? ?? '')) {
        continue;
      }
      var url = _commentUrl(pr, c);
      matches.add({
        'pr': pr['number'],
        'author': c['author'],
        'role': c['role'],
        'weight': c['weight'],
        if (c['isPrAuthor'] == true) 'isPrAuthor': true,
        'kind': c['kind'],
        if (c['path'] != null) 'path': c['path'],
        if (c['line'] != null) 'line': c['line'],
        if (bot != null) ...{
          'humanReply': comments.any((r) =>
              r['role'] != 'bot' &&
              r['threadId'] != null &&
              r['threadId'] == (c['threadId'] ?? c['id']) &&
              (r['createdAt'] as String).compareTo(c['createdAt'] as String) >
                  0),
          'resolved': c['threadResolved'] == true,
        },
        'text': excerpt(c['body'] as String? ?? '', _selectExcerptLength),
        if (url != null) 'url': url,
      });
    }
  }
  var reviewers = <String, String>{
    for (var m in matches) m['author'] as String: m['role'] as String,
  };
  return {
    'select': text.pattern,
    if (path != null) 'path': path.pattern,
    'comments': bot == null ? 'human' : 'bot',
    'n': matches.length,
    'weighted': matches.fold<double>(
        0, (sum, m) => sum + (m['weight'] as num? ?? 0).toDouble()),
    'prs': {for (var m in matches) m['pr']}.toList(),
    'reviewers': [
      for (var MapEntry(:key, :value) in reviewers.entries)
        {'login': key, 'role': value},
    ],
    if (bot != null) ...{
      'withHumanReply': matches.where((m) => m['humanReply'] == true).length,
      'resolved': matches.where((m) => m['resolved'] == true).length,
    },
    'matches': matches,
  };
}

String renderSelect(Map<String, Object?> s) {
  var b = StringBuffer()
    ..writeln('# Select: /${s['select']}/'
        '${s['path'] == null ? '' : ' path /${s['path']}/'} '
        '(${s['comments']} comments)')
    ..writeln()
    ..writeln('- comments: ${s['n']}')
    ..writeln('- weighted: ${(s['weighted'] as num).toStringAsFixed(1)}');
  if (s['comments'] == 'bot') {
    b
      ..writeln('- with human reply: ${s['withHumanReply']}')
      ..writeln('- threads resolved: ${s['resolved']}');
  }
  b
    ..writeln('- PRs (${(s['prs'] as List).length}): '
        '${[for (var n in s['prs'] as List) '#$n'].join(', ')}')
    ..writeln('- reviewers (${(s['reviewers'] as List).length}): '
        '${[
      for (var r in (s['reviewers'] as List).cast<Map>())
        '${r['login']} (${r['role']})',
    ].join(', ')}');
  var matches = (s['matches'] as List).cast<Map>();
  if (matches.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Matches')
      ..writeln();
  }
  for (var m in matches) {
    var author = m['isPrAuthor'] == true
        ? '${m['author']} (${m['role']}, PR author)'
        : '${m['author']} (${m['role']})';
    var state = m['humanReply'] == null
        ? ''
        : ' [${m['resolved'] == true ? 'resolved' : 'unresolved'}'
            '${m['humanReply'] == true ? ', human reply' : ''}]';
    var url = m['url'] == null ? '' : ' ${m['url']}';
    b.writeln('- #${m['pr']} $author ${_where(m)}$state: ${m['text']}$url');
  }
  return b.toString();
}

String _who(Map c) {
  var author =
      c['isPrAuthor'] == true ? '${c['author']} (PR author)' : c['author'];
  return '$author [${c['role']} ${c['weight']}]';
}

String _where(Map c) => c['path'] == null
    ? c['kind'] as String
    : '`${c['path']}${c['line'] == null ? '' : ':${c['line']}'}`';

/// The digest's one-paragraph summary.
String _digestHeader(Map<String, Object?> d) =>
    'Corpus: ${d['corpus']} (${d['prsInCorpus']} PRs, '
    '${d['prsSkippedAutomation']} automation skipped, '
    '${d['prsWithActivity']} with review activity). Human comments: '
    '${d['humanCommentsTotal']} (weighted '
    '${(d['humanCommentsWeighted'] as num).toStringAsFixed(1)}). '
    'Bot: ${d['bot']}: ${d['botThreads']} inline threads, '
    '${d['botThreadsResolved']} resolved, ${d['botThreadsWithHumanReply']} '
    'with human replies.';

String renderDigest(Map<String, Object?> d) {
  var b = StringBuffer()
    ..writeln('# Review digest: ${d['repo']}')
    ..writeln()
    ..writeln('${_digestHeader(d)} Trivial human comments (LGTM, thanks) '
        'omitted; text truncated to ${d['maxChars']} chars '
        '(${(d['maxChars'] as int) * 3} for replies in bot threads).');
  _table(b, 'Human comments by role', [
    'Role',
    'Comments',
    'Weighted'
  ], [
    for (var MapEntry(:key, :value)
        in (d['humanCommentsByRole'] as Map).entries)
      [
        key,
        (value as Map)['comments'],
        (value['weight'] as num).toStringAsFixed(1)
      ],
  ]);
  _table(b, 'Most-commented paths (inline)', [
    'Path',
    'Human',
    'Bot'
  ], [
    for (var p in (d['topPaths'] as List).cast<Map>())
      [p['path'], p['human'], p['bot']],
  ]);
  b
    ..writeln()
    ..writeln('## PRs');
  for (var pr in (d['prs'] as List).cast<Map>()) {
    b
      ..writeln()
      ..writeln('### #${pr['number']} ${pr['title']} '
          '(${pr['author']}, ${pr['authorRole']}, ${pr['outcome']})');
    for (var c in (pr['human'] as List).cast<Map>()) {
      b.writeln('- H ${_who(c)} ${_where(c)}: ${c['text']}');
    }
    for (var t in (pr['bot'] as List).cast<Map>()) {
      var state = [
        t['resolved'] == true ? 'resolved' : 'unresolved',
        if (t['outdated'] == true) 'outdated',
      ].join(', ');
      b.writeln('- B ${_where({...t, 'kind': 'inline'})} [$state]: '
          '${t['text']}');
      for (var r in (t['replies'] as List).cast<Map>()) {
        b.writeln('  - ↳ ${_who(r)}: ${r['text']}');
      }
    }
  }
  return b.toString();
}

Future<void> main(List<String> argv) async {
  var args = parseArgs(argv, flags: {'stdout', 'bot'});
  switch (args.positional) {
    case [] || ['collect']:
      await runCollect(args.options);
    case ['digest']:
      runDigest(args.options);
    default:
      usageError('Usage: dart collect.dart [collect|digest] [options]; see '
          'the library doc comment.');
  }
}
