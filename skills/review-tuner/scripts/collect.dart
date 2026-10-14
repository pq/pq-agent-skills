/// Collects pull request review activity for a repository over a date window
/// into a corpus (with a `.stats.json` review-density summary and a digest),
/// digests a corpus or counts the comments matching a theme (`--select`), and
/// reports a repo's agent guidance from a shallow clone (`guidance`).
///
/// Usage (also printed by `--help` and on a usage error):
///
///     dart collect.dart --repo <owner/name|alias>
///         [--since YYYY-MM-DD --until YYYY-MM-DD | --days N]
///         [--output-file <corpus.jsonl>] [--concurrency 4] [--max-chars 300]
///         [--config <path>]
///     dart collect.dart digest --corpus <corpus.jsonl> [--repo <owner/name>]
///         [--output-file <digest.json>] [--stdout] [--max-chars 300]
///         [--config <path>]
///     dart collect.dart digest --corpus <corpus.jsonl> --select <regex>
///         [--path <regex>] [--bot [--rebuttals <ids|@file>]]
///         [--output-file <select.json>] [--repo <owner/name>] [--config <path>]
///     dart collect.dart guidance --repo <owner/name|alias>
///         [--output-file <guidance.json>] [--config <path>]
///
/// Outputs, counting rules, and exit codes: `references/formats.md`.
library;

import 'dart:convert';
import 'dart:io';

import 'src/cli.dart';
import 'src/config.dart';
import 'src/corpus.dart';
import 'src/guidance.dart';

const usage = '''
Usage:
  dart collect.dart --repo <owner/name|alias>
      [--since YYYY-MM-DD --until YYYY-MM-DD | --days N]
      [--output-file <corpus.jsonl>] [--concurrency 4] [--max-chars 300]
      [--config <path>]
  dart collect.dart digest --corpus <corpus.jsonl> [--repo <owner/name>]
      [--output-file <digest.json>] [--stdout] [--max-chars 300]
      [--config <path>]
  dart collect.dart digest --corpus <corpus.jsonl> --select <regex>
      [--path <regex>] [--bot [--rebuttals <ids|@file>]]
      [--output-file <select.json>] [--repo <owner/name>] [--config <path>]
  dart collect.dart guidance --repo <owner/name|alias>
      [--output-file <guidance.json>] [--config <path>]''';

/// GitHub search returns at most this many results per query.
const _searchCap = 1000;

/// Default characters of comment text kept in a digest (`--max-chars`).
const _defaultMaxChars = 300;

/// Characters of comment text shown per `--select` match.
const _selectExcerptLength = 160;

/// Characters of context shown on each side of a `--select` match's span.
const _matchContext = 40;

/// Characters of reply text shown per human reply to a `--bot` match.
const _replyExcerptLength = 300;

/// A rebuttal by the PR's own author counts at this share of its role
/// weight (`references/rubric.md`).
const _authorRebuttalFactor = 0.5;

/// Human replies in bot threads keep this many times `--max-chars`, since
/// they carry the verdict on the bot's comment.
const _replyCharsFactor = 3;

/// Most-commented paths listed in a digest.
const _topPathCount = 15;

/// Characters of a commit SHA shown in markdown.
const _shaPrefixLength = 10;

/// Defaults for `--days` and `--concurrency`.
const _defaultDays = 90;
const _defaultConcurrency = 4;

/// Collection progress is reported every this many PRs.
const _progressInterval = 10;

/// Activity at which a login without a configured role is listed as a
/// candidate for the config's `people` or `roles`.
const _frequentParticipant = (authored: 2, comments: 5);

/// A login that authored at least `authored` PRs, or at least `share` of the
/// collected PRs (and `minAuthored`), with no substantive comments, is listed
/// as possible unconfigured automation.
const _possibleAutomation = (authored: 10, share: 0.2, minAuthored: 3);

/// Logins that look like AI agent accounts (a hint, not a default).
final _agentLogin = RegExp(r'(-agent|\[agent\])$', caseSensitive: false);

Future<void> main(List<String> argv) => guarded(usage, argv, () async {
      var command = 'collect';
      var rest = argv;
      if (argv.firstOrNull case var first? when !first.startsWith('--')) {
        command = first;
        rest = argv.sublist(1);
      }
      switch (command) {
        case 'collect':
          var args = parseArgs(rest, options: {
            'repo',
            'since',
            'until',
            'days',
            'output-file',
            'concurrency',
            'max-chars',
            'config',
          });
          if (args.positional.isNotEmpty) usageError('Unexpected arguments.');
          await runCollect(args.options);
        case 'digest':
          var args = parseArgs(rest, options: {
            'corpus',
            'repo',
            'output-file',
            'max-chars',
            'config',
            'select',
            'path',
            'rebuttals',
          }, flags: {
            'stdout',
            'bot',
          });
          if (args.positional.isNotEmpty) usageError('Unexpected arguments.');
          runDigest(args.options);
        case 'guidance':
          var args =
              parseArgs(rest, options: {'repo', 'output-file', 'config'});
          if (args.positional.isNotEmpty) usageError('Unexpected arguments.');
          await runGuidance(args.options);
        default:
          usageError('Unknown command "$command".');
      }
    });

// ---------------------------------------------------------------------------
// GitHub access
// ---------------------------------------------------------------------------

/// Runs a GraphQL [query] with string [vars] (`-f`) and int [ints] (`-F`),
/// returning `data`. GraphQL errors are failures, never empty results.
Future<Map<String, Object?>> graphql(
  String query, {
  Map<String, String> vars = const {},
  Map<String, int> ints = const {},
}) async {
  var out = await gh([
    'api',
    'graphql',
    '-f',
    'query=$query',
    for (var MapEntry(:key, :value) in vars.entries) ...['-f', '$key=$value'],
    for (var MapEntry(:key, :value) in ints.entries) ...['-F', '$key=$value'],
  ], step: 'gh api graphql');
  var response = jsonDecode(out) as Map<String, Object?>?;
  if (response?['errors'] case List errors when errors.isNotEmpty) {
    throw CommandException('gh api graphql', jsonEncode(errors));
  }
  if (response?['data'] case Map<String, Object?> data) return data;
  throw CommandException('gh api graphql', 'response has no data');
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
    throw CommandException(
      'gh api graphql',
      'search matched $total PRs but returned ${numbers.length} (GitHub caps '
          'search at $_searchCap); use a shorter window',
    );
  }
  return numbers..sort();
}

const _actor = '__typename login';

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
    throw CommandException('gh api graphql', 'PR #$number not found');
  }
  return pr;
}

// ---------------------------------------------------------------------------
// GraphQL -> corpus model
// ---------------------------------------------------------------------------

/// Turns a GraphQL `pullRequest` node into a [PullRequest], resolving every
/// participant's role and weight from [config].
PullRequest parsePr(Map<String, Object?> node, Config config, RepoConfig repo) {
  var author = _login(node['author']);
  var association = node['authorAssociation'] as String?;
  var role = config.roleFor(repo, author, authorAssociation: association);
  return PullRequest(
    number: node['number'] as int,
    title: node['title'] as String? ?? '',
    url: node['url'] as String?,
    state: node['state'] as String?,
    isDraft: node['isDraft'] == true,
    createdAt: node['createdAt'] as String?,
    closedAt: node['closedAt'] as String?,
    mergedAt: node['mergedAt'] as String?,
    baseRefName: node['baseRefName'] as String?,
    baseRefOid: node['baseRefOid'] as String?,
    headRefOid: node['headRefOid'] as String?,
    labels: [for (var l in _nodes(node['labels'])) l['name'] as String],
    files: [
      for (var f in _nodes(node['files']))
        (
          path: f['path'] as String,
          additions: f['additions'] as int? ?? 0,
          deletions: f['deletions'] as int? ?? 0,
          changeType: f['changeType'] as String? ?? '',
        ),
    ],
    author: author,
    authorRole: role,
    authorWeight: config.weightFor(role),
    association: association,
    comments: _CommentParser(config, repo, author).parse(node),
    truncated: [
      for (var key in ['files', 'reviewThreads', 'reviews'])
        if (_hasNextPage(node[key])) key,
      if (_hasNextPage(node['comments'])) 'issueComments',
      if (_nodes(node['reviewThreads']).any((t) => _hasNextPage(t['comments'])))
        'threadComments',
    ],
    excludedReason: role == 'bot' ? 'automation-author' : null,
  );
}

/// Turns the comment connections of a GraphQL PR node into [Comment]s.
final class _CommentParser {
  _CommentParser(this.config, this.repo, this.prAuthor);

  final Config config;
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
    var association = j['authorAssociation'] as String?;
    var role = config.roleFor(repo, login, authorAssociation: association);
    var body = j['body'] as String? ?? '';
    return Comment(
      kind: kind,
      id: j['databaseId'] as int,
      author: login,
      role: role,
      weight: config.weightFor(role),
      association: association,
      isPrAuthor: login.toLowerCase() == prAuthor.toLowerCase(),
      body: body,
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
      severity: role == 'bot' ? botSeverity(body) : null,
    );
  }
}

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

// ---------------------------------------------------------------------------
// Collect
// ---------------------------------------------------------------------------

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
  var days = int.tryParse(options['days'] ?? '$_defaultDays');
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

/// The repo for a `--repo` argument (a usage error if malformed).
RepoConfig _repoOption(Config config, String slug) =>
    config.repo(slug) ??
    usageError('Unknown repo "$slug": use owner/name or an alias.');

Future<void> runGuidance(Map<String, String> options) async {
  var slug = options['repo'] ?? usageError('Missing --repo <owner/name>.');
  var config = loadConfig(path: options['config']);
  var repo = _repoOption(config, slug);
  String head;
  try {
    head = await updateHead(config, repo);
  } on CommandException catch (e) {
    fail('Failed to clone or update ${repo.slug}: $e');
  }
  var report = guidanceReport(repo, head);
  if (options['output-file'] case var path?) writeJson(path, report);
  stdout.write(renderGuidance(report));
}

Future<void> runCollect(Map<String, String> options) async {
  var slug = options['repo'] ?? usageError('Missing --repo <owner/name>.');
  var config = loadConfig(path: options['config']);
  var repo = _repoOption(config, slug);
  var window = parseWindow(options);
  var concurrency =
      int.tryParse(options['concurrency'] ?? '$_defaultConcurrency') ?? 0;
  if (concurrency < 1) usageError('--concurrency must be a positive integer.');
  var output = options['output-file'] ??
      '${config.repoDir(repo)}/corpus/${window.since}_${window.until}.jsonl';
  var maxChars = _maxChars(options);

  var (:prs, :failures) = await collectPrs(
      config: config, repo: repo, window: window, concurrency: concurrency);
  writeCorpus(output, prs);
  var digest = buildDigest(prs, repo, output, maxChars);
  var digestPaths = _defaultDigestPaths(output);
  writeDigest(digest, digestPaths.json, digestPaths.md);
  var statsPath = '${_base(output)}.stats.json';
  var stats = {
    ...computeStats(prs, config, repo, failures, window),
    'humanCommentsTotal': digest['humanCommentsTotal'],
    'humanCommentsWeighted': digest['humanCommentsWeighted'],
  };
  writeJson(statsPath, stats);
  var bot = stats['bot'] as Map;
  stdout
    ..write(renderStats(stats))
    ..writeln()
    ..writeln('Summary: ${stats['prsConsidered']} PRs considered, '
        '${stats['humanCommentsTotal']} human comments, '
        '${bot['botInlineComments']} bot inline comments.')
    ..writeln()
    ..writeln('Wrote:')
    ..writeln('- $output')
    ..writeln('- $statsPath')
    ..writeln('- ${digestPaths.md}')
    ..writeln('- ${digestPaths.json}');
  if (failures.isNotEmpty) exit(exitFailure);
}

/// Fetches every PR closed in [window], at most [concurrency] at a time.
/// Returns the PRs (sorted by number) and the failed fetches by number.
Future<({List<PullRequest> prs, Map<int, String> failures})> collectPrs({
  required Config config,
  required RepoConfig repo,
  required ({String since, String until}) window,
  required int concurrency,
}) async {
  List<int> numbers;
  try {
    numbers = await listClosedPrs(repo.slug, window.since, window.until);
  } on CommandException catch (e) {
    fail('Failed to list PRs: $e');
  }
  stderr.writeln('Listed ${numbers.length} PRs; collecting activity...');
  var prs = <PullRequest>[];
  var failures = <int, String>{};
  var done = 0;
  await pooled(numbers, concurrency, (number) async {
    try {
      prs.add(parsePr(await fetchPr(repo, number), config, repo));
    } on CommandException catch (e) {
      failures[number] = '$e';
    } on FormatException catch (e) {
      failures[number] = 'invalid response: ${e.message}';
    }
    if (++done % _progressInterval == 0) {
      stderr.writeln('  $done/${numbers.length}');
    }
  });
  prs.sort((a, b) => a.number.compareTo(b.number));
  return (prs: prs, failures: failures);
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

/// Density statistics over the non-excluded PRs.
Map<String, Object?> computeStats(
  List<PullRequest> prs,
  Config config,
  RepoConfig repo,
  Map<int, String> failures,
  ({String since, String until}) window,
) {
  var considered = prs.where((p) => p.considered).toList();
  var created = [
    for (var p in prs)
      if (p.createdAt case var c? when c.length >= 10) c.substring(0, 10),
  ]..sort();
  return {
    'repo': repo.slug,
    'window': {'since': window.since, 'until': window.until},
    'createdRange': {
      'earliest': created.firstOrNull,
      'latest': created.lastOrNull,
    },
    'collectedAt': DateTime.now().toUtc().toIso8601String(),
    'prsTotal': prs.length + failures.length,
    'prsCollected': prs.length,
    'prsFailed': failures.length,
    'prsExcludedAutomation': prs.length - considered.length,
    'prsConsidered': considered.length,
    'merged': considered.where((p) => p.merged).length,
    'closedUnmerged': considered.where((p) => !p.merged).length,
    'prsByAuthorRole': _tally([for (var p in considered) p.authorRole]),
    'prsWithHumanInlineComments': considered
        .where(
            (p) => p.reviewerComments.any((c) => c.kind == CommentKind.inline))
        .length,
    'prsWithSubstantiveHumanComments': considered
        .where((p) => p.reviewerComments.any((c) => isSubstantive(c.body)))
        .length,
    ..._reviewerStats(considered),
    'bot': _botStats(considered, repo.bot),
    'truncatedPrs': {
      for (var p in prs)
        if (p.truncated.isNotEmpty) '${p.number}': p.truncated,
    },
    'unconfiguredFrequentParticipants': _unconfigured(considered, config, repo),
    ..._accountHints(prs, config, repo),
    'failedPrs': {
      for (var MapEntry(:key, :value) in failures.entries) '$key': value,
    },
  };
}

/// The reviewer [bot]'s inline activity and the human response to it.
Map<String, Object?> _botStats(List<PullRequest> prs, String bot) {
  var inline = [
    for (var p in prs)
      ...p.comments
          .where((c) => c.author == bot && c.kind == CommentKind.inline),
  ];
  return {
    'login': bot,
    'prsWithBotActivity':
        prs.where((p) => p.comments.any((c) => c.author == bot)).length,
    'botInlineComments': inline.length,
    'botInlineResolved': inline.where((c) => c.resolved == true).length,
    'humanRepliesToBotInline': [
      for (var p in prs)
        for (var root in p.botThreadRoots(bot)) ...p.humanReplies(root),
    ].length,
  };
}

/// Substantive reviewer comments by role and by reviewer.
Map<String, Object?> _reviewerStats(List<PullRequest> prs) {
  var byRole = <String, int>{};
  var byReviewer = <String, Map<String, Object?>>{};
  for (var pr in prs) {
    var seen = <String>{};
    for (var c in pr.reviewerComments.where((c) => isSubstantive(c.body))) {
      byRole.update(c.role, (v) => v + 1, ifAbsent: () => 1);
      var r = byReviewer.putIfAbsent(
          c.author,
          () => {
                'role': c.role,
                'weight': c.weight,
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

/// Active humans with no explicit role in the config (their role came from
/// GitHub's association): candidates for the config's `people` or `roles`.
List<Map<String, Object?>> _unconfigured(
    List<PullRequest> prs, Config config, RepoConfig repo) {
  var counts = <String, ({int authored, int comments})>{};
  for (var pr in prs) {
    var a = counts[pr.author] ?? (authored: 0, comments: 0);
    counts[pr.author] = (authored: a.authored + 1, comments: a.comments);
    for (var c in pr.comments.where((c) => c.isHuman)) {
      var p = counts[c.author] ?? (authored: 0, comments: 0);
      counts[c.author] = (authored: p.authored, comments: p.comments + 1);
    }
  }
  return [
    for (var MapEntry(key: login, value: n) in counts.entries)
      if (!config.hasRole(repo, login) &&
          !_isAutomated(config.roleFor(repo, login)) &&
          (n.authored >= _frequentParticipant.authored ||
              n.comments >= _frequentParticipant.comments))
        {'login': login, 'authored': n.authored, 'comments': n.comments},
  ]..sort((a, b) => (b['comments'] as int).compareTo(a['comments'] as int));
}

bool _isAutomated(String role) => role == 'bot' || role == 'agent';

/// Accounts over all collected [prs] (excluded ones too) that look like
/// automation or AI agents but have no role, pattern match, or list entry:
/// `possibleAutomation` (many PRs, no substantive comments) and
/// `possibleAgents` (logins ending in `-agent` or `[agent]`).
Map<String, Object?> _accountHints(
    List<PullRequest> prs, Config config, RepoConfig repo) {
  var authored = <String, int>{};
  var comments = <String, int>{};
  var substantive = <String, int>{};
  for (var pr in prs) {
    authored.update(pr.author, (n) => n + 1, ifAbsent: () => 1);
    for (var c in pr.comments) {
      comments.update(c.author, (n) => n + 1, ifAbsent: () => 1);
      if (isSubstantive(c.body)) {
        substantive.update(c.author, (n) => n + 1, ifAbsent: () => 1);
      }
    }
  }
  bool unconfigured(String login) =>
      !config.hasRole(repo, login) &&
      !_isAutomated(config.roleFor(repo, login));
  Map<String, Object?> entry(String login) => {
        'login': login,
        'authored': authored[login] ?? 0,
        'comments': comments[login] ?? 0,
      };
  int byAuthored(Map a, Map b) =>
      (b['authored'] as int).compareTo(a['authored'] as int);
  var limits = _possibleAutomation;
  return {
    'possibleAutomation': [
      for (var MapEntry(key: login, value: n) in authored.entries)
        if ((n >= limits.authored ||
                (n >= limits.minAuthored && n >= limits.share * prs.length)) &&
            (substantive[login] ?? 0) == 0 &&
            unconfigured(login))
          entry(login),
    ]..sort(byAuthored),
    'possibleAgents': [
      for (var login in {...authored.keys, ...comments.keys})
        if (_agentLogin.hasMatch(login) && unconfigured(login)) entry(login),
    ]..sort(byAuthored),
  };
}

Map<String, int> _tally(Iterable<String> values) {
  var counts = <String, int>{};
  for (var v in values) {
    counts.update(v, (n) => n + 1, ifAbsent: () => 1);
  }
  return counts;
}

/// Keys of the stats summary table, in order.
const _summaryKeys = [
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
];

String renderStats(Map<String, Object?> s) {
  var b = StringBuffer();
  var window = s['window'] as Map;
  b
    ..writeln('# Review density: ${s['repo']}')
    ..writeln()
    ..writeln(
        'Window: PRs closed ${window['since']} → ${window['until']} (UTC)')
    ..writeln();
  if (s['createdRange'] case {'earliest': var from?, 'latest': var to?}) {
    b
      ..writeln('Created: $from → $to (UTC)')
      ..writeln();
  }
  b
    ..writeln('| Metric | Value |')
    ..writeln('|---|---|');
  for (var key in _summaryKeys) {
    var v = s[key];
    b.writeln('| $key | ${v is double ? v.toStringAsFixed(1) : v} |');
  }
  for (var MapEntry(:key, :value) in (s['bot'] as Map).entries) {
    b.writeln('| bot.$key | $value |');
  }
  _table(b, 'PRs by author role', [
    'Role',
    'PRs'
  ], [
    for (var MapEntry(:key, :value) in (s['prsByAuthorRole'] as Map).entries)
      [key, value],
  ]);
  _reviewerTable(b, s['reviewers'] as Map);
  _list(b, 'Unconfigured frequent participants', [
    for (var u in (s['unconfiguredFrequentParticipants'] as List).cast<Map>())
      '${u['login']}: authored ${u['authored']}, comments ${u['comments']}',
  ]);
  _list(
      b,
      'Possible automation (unconfigured; add to automationAuthors '
      'if so)',
      [
        for (var u
            in (s['possibleAutomation'] as List? ?? const []).cast<Map>())
          '${u['login']}: authored ${u['authored']}, '
              'no substantive comments',
      ]);
  _list(
      b, 'Possible agent accounts (unconfigured; add to agentAuthors if so)', [
    for (var u in (s['possibleAgents'] as List? ?? const []).cast<Map>())
      '${u['login']}: authored ${u['authored']}, '
          'comments ${u['comments']}',
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

/// Reviewers by substantive comments, most first.
void _reviewerTable(StringBuffer b, Map reviewers) {
  var sorted = reviewers.entries.toList()
    ..sort((a, b) => ((b.value as Map)['substantiveComments'] as int)
        .compareTo((a.value as Map)['substantiveComments'] as int));
  _table(b, 'Substantive reviewer comments (non-author humans)', [
    'Reviewer',
    'Role',
    'Weight',
    'Comments',
    'PRs'
  ], [
    for (var MapEntry(:key, :value) in sorted)
      [
        key,
        for (var f in ['role', 'weight', 'substantiveComments', 'prs'])
          (value as Map)[f],
      ],
  ]);
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
  var text = _flatten(body);
  return text.length <= max ? text : '${text.substring(0, max)}…';
}

/// [body] with badge images as `[high]` and whitespace collapsed.
String _flatten(String body) => body
    .replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => '[${m[1]}]')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

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

/// The reply ids in a `--rebuttals` value: comma-separated, or `@<file>`
/// with one id per line (`#` starts a comment). A bad id on the command
/// line is a usage error; a missing or malformed file fails.
Set<int> _replyIds(String value) {
  if (!value.startsWith('@')) {
    var ids = value.split(',').map((s) => int.tryParse(s.trim()));
    if (ids.contains(null)) {
      usageError('--rebuttals must be comma-separated reply ids or @<file>.');
    }
    return ids.cast<int>().toSet();
  }
  var path = value.substring(1);
  var file = File(path);
  if (!file.existsSync()) fail('Rebuttals file not found: $path');
  var ids = <int>{};
  var lines = file.readAsLinesSync();
  for (var (i, line) in lines.indexed) {
    var text = line.split('#').first.trim();
    if (text.isEmpty) continue;
    ids.add(int.tryParse(text) ??
        fail('$path:${i + 1}: expected one reply id per line, got "$text".'));
  }
  return ids;
}

Map<String, Object?> _digestComment(Comment c, int max) => {
      'author': c.author,
      'role': c.role,
      'weight': c.weight,
      if (c.isPrAuthor) 'isPrAuthor': true,
      'kind': c.kind.name,
      if (c.path != null) 'path': c.path,
      if (c.line != null) 'line': c.line,
      if (c.commitId != null) 'commitId': c.commitId,
      'text': excerpt(c.body, max),
    };

/// Digest of one PR, or null if it has nothing worth showing. Human replies
/// in bot threads keep [_replyCharsFactor] x [maxChars].
Map<String, Object?>? digestPr(PullRequest pr, String bot, int maxChars) {
  var roots = pr.botThreadRoots(bot).toList();
  var rootIds = {for (var r in roots) r.id};
  var human = [
    for (var c in pr.comments)
      if (c.isHuman && !rootIds.contains(c.threadId) && isSubstantive(c.body))
        _digestComment(c, maxChars),
  ];
  var botThreads = [
    for (var root in roots)
      {
        'path': root.path,
        'line': root.line,
        if (root.commitId != null) 'commitId': root.commitId,
        'resolved': root.resolved,
        'outdated': root.outdated,
        'text': excerpt(root.body, maxChars),
        'replies': [
          for (var r in pr.humanReplies(root))
            _digestComment(r, maxChars * _replyCharsFactor),
        ],
      },
  ];
  if (human.isEmpty && botThreads.isEmpty) return null;
  return {
    'number': pr.number,
    'title': pr.title,
    'author': pr.author,
    'authorRole': pr.authorRole,
    'outcome': pr.merged ? 'merged' : 'closed-unmerged',
    'human': human,
    'bot': botThreads,
  };
}

/// Totals by role and most-commented paths over the digested PRs. Comments
/// by a PR's own author are listed but not counted (only tallied).
Map<String, Object?> digestTotals(List<Map<String, Object?>> prs) {
  var humans = [
    for (var pr in prs) ...[
      ...(pr['human'] as List).cast<Map>(),
      for (var t in (pr['bot'] as List).cast<Map>())
        ...(t['replies'] as List).cast<Map>(),
    ],
  ];
  var threads = [for (var pr in prs) ...(pr['bot'] as List).cast<Map>()];
  var reviewers = humans.where((c) => c['isPrAuthor'] != true).toList();
  var byRole = <String, ({int comments, double weight})>{};
  var weighted = 0.0;
  for (var c in reviewers) {
    var weight = (c['weight'] as num? ?? 0).toDouble();
    weighted += weight;
    var r = byRole[c['role']] ?? (comments: 0, weight: 0.0);
    byRole[c['role'] as String] =
        (comments: r.comments + 1, weight: r.weight + weight);
  }
  return {
    'humanCommentsTotal': reviewers.length,
    'humanCommentsWeighted': weighted,
    'prAuthorComments': humans.length - reviewers.length,
    'humanCommentsByRole': {
      for (var MapEntry(:key, :value) in byRole.entries)
        key: {'comments': value.comments, 'weight': value.weight},
    },
    'botThreads': threads.length,
    'botThreadsResolved': threads.where((t) => t['resolved'] == true).length,
    'botThreadsWithHumanReply':
        threads.where((t) => (t['replies'] as List).isNotEmpty).length,
    'topPaths': _topPaths(
      human: [
        for (var c in humans)
          if (c['kind'] == 'inline') c['path']
      ],
      bot: [for (var t in threads) t['path']],
    ),
  };
}

/// The [_topPathCount] paths with the most inline comments ([human] and
/// [bot] list one path per comment; non-strings are ignored).
List<Map<String, Object?>> _topPaths(
    {required List<Object?> human, required List<Object?> bot}) {
  var paths = <String, ({int human, int bot})>{};
  for (var p in human.whereType<String>()) {
    var v = paths[p] ?? (human: 0, bot: 0);
    paths[p] = (human: v.human + 1, bot: v.bot);
  }
  for (var p in bot.whereType<String>()) {
    var v = paths[p] ?? (human: 0, bot: 0);
    paths[p] = (human: v.human, bot: v.bot + 1);
  }
  var top = paths.entries.toList()
    ..sort((a, b) =>
        (b.value.human + b.value.bot).compareTo(a.value.human + a.value.bot));
  return [
    for (var e in top.take(_topPathCount))
      {'path': e.key, 'human': e.value.human, 'bot': e.value.bot},
  ];
}

/// The digest of [corpus].
Map<String, Object?> buildDigest(List<PullRequest> corpus, RepoConfig repo,
    String corpusPath, int maxChars) {
  var considered = corpus.where((p) => p.considered).toList();
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
  writeText(mdPath, renderDigest(digest));
}

void runDigest(Map<String, String> options) {
  var corpusPath =
      options['corpus'] ?? usageError('Missing --corpus <corpus.jsonl>.');
  var select = options['select'];
  if (select == null) {
    for (var flag in ['path', 'bot', 'rebuttals']) {
      if (options.containsKey(flag)) usageError('--$flag requires --select.');
    }
  }
  if (options.containsKey('rebuttals') && !options.containsKey('bot')) {
    usageError('--rebuttals requires --bot.');
  }
  var selectRegex = select == null ? null : _regex('select', select);
  var rebuttals = switch (options['rebuttals']) {
    var ids? => _replyIds(ids),
    null => null,
  };
  var pathRegex = switch (options['path']) {
    var path? => _regex('path', path),
    null => null,
  };
  var maxChars = _maxChars(options);
  var corpus = readCorpus(corpusPath);
  var config = loadConfig(path: options['config']);
  var repo = switch (options['repo']) {
    var slug? => _repoOption(config, slug),
    null => config.repo(corpus.firstOrNull?.slug ?? '') ??
        usageError('Cannot infer the repo from the corpus; pass --repo.'),
  };

  if (selectRegex != null) {
    var result = {
      'repo': repo.slug,
      'corpus': corpusPath,
      ...selectComments(corpus, selectRegex, pathRegex,
          bot: repo.bot,
          botComments: options.containsKey('bot'),
          rebuttals: rebuttals),
    };
    if (options['output-file'] case var path?) writeJson(path, result);
    stdout.write(renderSelect(result));
    return;
  }
  _redigest(corpus, repo, corpusPath, maxChars, options);
}

/// `digest` without `--select`: rewrites the digest files for [corpus].
void _redigest(List<PullRequest> corpus, RepoConfig repo, String corpusPath,
    int maxChars, Map<String, String> options) {
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

// ---------------------------------------------------------------------------
// Select
// ---------------------------------------------------------------------------

/// Comments in non-automation PRs whose full body matches [text] (and whose
/// path matches [path], if given): substantive human comments (plus every
/// human reply in a [bot] thread), or with [botComments] those by the
/// reviewer [bot] (other bots, such as CLA or merge bots, are skipped).
/// Human-mode counts leave out comments by the PR's own author. With
/// [botComments], counts cover the bot's inline comments (review summaries
/// are listed and counted apart), each match lists its human replies with
/// their comment ids, and the replies whose ids are in [rebuttals] count as
/// rebuttals, weighted as in `references/rubric.md`. An id in [rebuttals]
/// that is not such a reply fails.
Map<String, Object?> selectComments(
    List<PullRequest> corpus, RegExp text, RegExp? path,
    {required String bot, required bool botComments, Set<int>? rebuttals}) {
  var matches = <Map<String, Object?>>[];
  // With [botComments]: human replies in the matched threads, once each.
  var replies = <(int, int), Map<String, Object?>>{};
  for (var pr in corpus.where((p) => p.considered)) {
    var botRoots = {for (var r in pr.botThreadRoots(bot)) r.id};
    bool wanted(Comment c) => botComments
        ? c.author == bot
        : c.isHuman && (isSubstantive(c.body) || botRoots.contains(c.threadId));
    for (var c in pr.comments.where(wanted)) {
      if (!text.hasMatch(c.body)) continue;
      if (path != null && !path.hasMatch(c.path ?? '')) continue;
      var m = _selectMatch(pr, c, text);
      if (botComments) {
        var thread = <Map<String, Object?>>[];
        for (var r in pr.humanReplies(c)) {
          var reply = _selectReply(pr, r, rebuttals);
          thread.add(reply);
          replies[(pr.number, r.id)] = reply;
        }
        m['replies'] = thread;
      }
      matches.add(m);
    }
  }
  if (rebuttals != null) {
    var unknown = rebuttals.difference({for (var (_, id) in replies.keys) id});
    if (unknown.isNotEmpty) {
      fail('Not a reply to a matched bot comment: ${unknown.join(', ')}. '
          'Check the ids; the reply may sit on a bot comment that the '
          '--select regex does not match.');
    }
  }
  return {
    'select': text.pattern,
    if (path != null) 'path': path.pattern,
    'comments': botComments ? 'bot' : 'human',
    ...botComments
        ? _botCounts(matches, replies, classified: rebuttals != null)
        : _humanCounts(matches),
    'matches': matches,
  };
}

Map<String, Object?> _humanCounts(List<Map<String, Object?>> matches) {
  var counted = matches.where((m) => m['isPrAuthor'] != true).toList();
  var reviewers = <String, String>{
    for (var m in counted) m['author'] as String: m['role'] as String,
  };
  return {
    'n': counted.length,
    'weighted': counted.fold<double>(
        0, (sum, m) => sum + (m['weight'] as num? ?? 0).toDouble()),
    'prAuthorComments': matches.length - counted.length,
    'prs': {for (var m in counted) m['pr']}.toList(),
    'reviewers': [
      for (var MapEntry(:key, :value) in reviewers.entries)
        {'login': key, 'role': value},
    ],
  };
}

/// Counts for `--bot`: [replies] are keyed by (PR, comment id). With
/// [classified], rebuttals count once per (person, PR), a PR author's at
/// [_authorRebuttalFactor] x role weight.
Map<String, Object?> _botCounts(List<Map<String, Object?>> matches,
    Map<(int, int), Map<String, Object?>> replies,
    {required bool classified}) {
  var inline = matches.where((m) => m['kind'] == 'inline').toList();
  var repliesByRole = <String, int>{};
  for (var r in replies.values) {
    repliesByRole[r['role'] as String] = (repliesByRole[r['role']] ?? 0) + 1;
  }
  var rebuttals =
      <(String, int), ({String role, bool author, double weight})>{};
  for (var MapEntry(key: (pr, _), value: r) in replies.entries) {
    if (r['rebuttal'] != true) continue;
    var author = r['isPrAuthor'] == true;
    rebuttals.putIfAbsent(
        (r['author'] as String, pr),
        () => (
              role: r['role'] as String,
              author: author,
              weight: (r['weight'] as num).toDouble() *
                  (author ? _authorRebuttalFactor : 1),
            ));
  }
  var rebuttalsByRole = <String, int>{};
  for (var r in rebuttals.values) {
    rebuttalsByRole[r.role] = (rebuttalsByRole[r.role] ?? 0) + 1;
  }
  return {
    'n': inline.length,
    'prs': {for (var m in inline) m['pr']}.toList(),
    'inline': inline.length,
    'reviewSummaries': matches.length - inline.length,
    'withHumanReply':
        matches.where((m) => (m['replies'] as List).isNotEmpty).length,
    'resolved': matches.where((m) => m['resolved'] == true).length,
    'replies': replies.length,
    'repliesByRole': repliesByRole,
    'authorReplies':
        replies.values.where((r) => r['isPrAuthor'] == true).length,
    if (classified) ...{
      'rebuttals': rebuttals.length,
      'rebuttalReplies':
          replies.values.where((r) => r['rebuttal'] == true).length,
      'authorRebuttals': rebuttals.values.where((r) => r.author).length,
      'rebuttalsByRole': rebuttalsByRole,
      'rebuttalPrs': {for (var (_, pr) in rebuttals.keys) pr}.toList(),
      'rebuttalWeight':
          rebuttals.values.fold<double>(0, (sum, r) => sum + r.weight),
      'otherReplies': [
        for (var MapEntry(key: (pr, _), value: r) in replies.entries)
          if (r['rebuttal'] != true) {'pr': pr, ...r},
      ],
    },
  };
}

Map<String, Object?> _selectMatch(PullRequest pr, Comment c, RegExp text) => {
      'pr': pr.number,
      'author': c.author,
      'role': c.role,
      'weight': c.weight,
      if (c.isPrAuthor) 'isPrAuthor': true,
      'kind': c.kind.name,
      if (c.path != null) 'path': c.path,
      if (c.line != null) 'line': c.line,
      if (c.commitId != null) 'commitId': c.commitId,
      if (c.isBot) ...{
        'humanReply': pr.humanReplies(c).isNotEmpty,
        if (pr.humanReplies(c).any((r) => r.isPrAuthor)) 'authorReply': true,
        'resolved': c.resolved == true,
      },
      'text': excerpt(c.body, _selectExcerptLength),
      'match': _span(c.body, text),
      if (pr.commentUrl(c) case var url?) 'url': url,
    };

/// A human reply to a `--bot` match, with its comment id; with [rebuttals],
/// `rebuttal` says whether the id is listed.
Map<String, Object?> _selectReply(
        PullRequest pr, Comment r, Set<int>? rebuttals) =>
    {
      'id': r.id,
      'author': r.author,
      'role': r.role,
      'isPrAuthor': r.isPrAuthor,
      'weight': r.weight,
      if (rebuttals != null) 'rebuttal': rebuttals.contains(r.id),
      if (pr.commentUrl(r) case var url?) 'url': url,
      'text': excerpt(r.body, _replyExcerptLength),
    };

/// The first span of [body] that [text] matches, with [_matchContext]
/// characters on each side (`…` marks a cut). Matched in the [_flatten]ed
/// body when possible, so badges and line breaks read cleanly.
String _span(String body, RegExp text) {
  var flat = _flatten(body);
  if (text.firstMatch(flat) == null) flat = body;
  var match = text.firstMatch(flat)!;
  var start = (match.start - _matchContext).clamp(0, flat.length);
  var end = (match.end + _matchContext).clamp(0, flat.length);
  var span = excerpt(
      flat.substring(start, end), _selectExcerptLength + 2 * _matchContext);
  return '${start > 0 ? '…' : ''}$span'
      '${end < flat.length && !span.endsWith('…') ? '…' : ''}';
}

String renderSelect(Map<String, Object?> s) {
  var bot = s['comments'] == 'bot';
  var b = StringBuffer()
    ..writeln('# Select: /${s['select']}/'
        '${s['path'] == null ? '' : ' path /${s['path']}/'} '
        '(${s['comments']} comments)')
    ..writeln();
  if (bot) {
    b.writeln('- inline comments: ${s['n']}; review summaries (listed, not '
        'counted): ${s['reviewSummaries']}');
  } else {
    b.writeln('- comments: ${s['n']}');
  }
  if (s['weighted'] case num weighted) {
    b.writeln('- weighted: ${weighted.toStringAsFixed(1)}');
  }
  if (s['prAuthorComments'] case int n when n > 0) {
    b.writeln('- by the PR author (listed, not counted): $n');
  }
  if (bot) {
    b
      ..writeln('- with human reply: ${s['withHumanReply']}')
      ..writeln('- human replies: ${s['replies']}'
          '${_counts(s['repliesByRole'] as Map)}; '
          'by the PR author: ${s['authorReplies']}')
      ..writeln('- threads resolved: ${s['resolved']}');
    if (s['rebuttals'] case int n) {
      b
        ..writeln('- rebuttals (one per person per PR): $n'
            '${_counts(s['rebuttalsByRole'] as Map)}, '
            '${s['authorRebuttals']} by PR authors; from '
            '${s['rebuttalReplies']} listed replies; PRs: '
            '${_prs(s['rebuttalPrs'] as List)}')
        ..writeln('- rebuttal weight (PR authors at half weight): '
            '${(s['rebuttalWeight'] as num).toStringAsFixed(2)}')
        ..writeln('- other replies: ${(s['otherReplies'] as List).length} '
            '(read them for acceptances, and the rebuttals to confirm them)');
    } else {
      b.writeln('- classify replies: pass the rebuttal reply ids with '
          '--rebuttals');
    }
  }
  b.writeln('- PRs (${(s['prs'] as List).length}): ${_prs(s['prs'] as List)}');
  if (!bot) {
    b.writeln('- reviewers (${(s['reviewers'] as List).length}): '
        '${[
      for (var r in (s['reviewers'] as List).cast<Map>())
        '${r['login']} (${r['role']})',
    ].join(', ')}');
  }
  var matches = (s['matches'] as List).cast<Map>();
  if (matches.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Matches')
      ..writeln();
  }
  for (var m in matches) {
    b
      ..writeln(_selectLine(m))
      ..writeln('  - match: ${m['match']}');
    for (var r in (m['replies'] as List? ?? const []).cast<Map>()) {
      var who = r['isPrAuthor'] == true
          ? '${r['author']} (${r['role']}, PR author)'
          : '${r['author']} (${r['role']})';
      var tag = switch (r['rebuttal']) {
        true => ' [rebuttal]',
        false => ' [other]',
        _ => '',
      };
      var url = r['url'] == null ? '' : ' ${r['url']}';
      b.writeln('  - ↳ [r:${r['id']}] $who$tag: ${r['text']}$url');
    }
  }
  return b.toString();
}

/// ` (key n, key n)` for a non-empty [counts] map, else empty.
String _counts(Map counts) => counts.isEmpty
    ? ''
    : ' (${[
        for (var MapEntry(:key, :value) in counts.entries) '$key $value'
      ].join(', ')})';

String _prs(List prs) => [for (var n in prs) '#$n'].join(', ');

/// One `--select` match as a markdown list item.
String _selectLine(Map m) {
  var author = m['isPrAuthor'] == true
      ? '${m['author']} (${m['role']}, PR author)'
      : '${m['author']} (${m['role']})';
  var state = m['humanReply'] == null
      ? ''
      : ' [${m['resolved'] == true ? 'resolved' : 'unresolved'}'
          '${m['humanReply'] == true ? ', human reply' : ''}'
          '${m['authorReply'] == true ? ' (incl. PR author)' : ''}]';
  var url = m['url'] == null ? '' : ' ${m['url']}';
  return '- #${m['pr']} $author ${_where(m)}$state: ${m['text']}$url';
}

// ---------------------------------------------------------------------------
// Digest markdown
// ---------------------------------------------------------------------------

String _who(Map c) {
  var author =
      c['isPrAuthor'] == true ? '${c['author']} (PR author)' : c['author'];
  return '$author [${c['role']} ${c['weight']}]';
}

/// Location of [c]: `path:line` (plus `@<commit>` when known), or its kind.
String _where(Map c) {
  if (c['path'] == null) return c['kind'] as String;
  var line = c['line'] == null ? '' : ':${c['line']}';
  var commit = c['commitId'] is String
      ? ' @${(c['commitId'] as String).substring(0, _shaPrefixLength)}'
      : '';
  return '`${c['path']}$line`$commit';
}

/// The digest's one-paragraph summary.
String _digestHeader(Map<String, Object?> d) =>
    'Corpus: ${d['corpus']} (${d['prsInCorpus']} PRs, '
    '${d['prsSkippedAutomation']} automation skipped, '
    '${d['prsWithActivity']} with review activity). Human comments: '
    '${d['humanCommentsTotal']} (weighted '
    '${(d['humanCommentsWeighted'] as num).toStringAsFixed(1)}; '
    '${d['prAuthorComments']} more by PR authors, not counted). '
    'Bot: ${d['bot']}: ${d['botThreads']} inline threads, '
    '${d['botThreadsResolved']} resolved, ${d['botThreadsWithHumanReply']} '
    'with human replies.';

String renderDigest(Map<String, Object?> d) {
  var b = StringBuffer()
    ..writeln('# Review digest: ${d['repo']}')
    ..writeln()
    ..writeln('${_digestHeader(d)} Trivial human comments (LGTM, thanks) '
        'omitted; text truncated to ${d['maxChars']} chars '
        '(${(d['maxChars'] as int) * _replyCharsFactor} for replies in bot '
        'threads).');
  _table(b, 'Human comments by role (excluding PR authors)', [
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
    _renderDigestPr(b, pr);
  }
  return b.toString();
}

/// One digested PR: its human comments (`H`), then bot threads (`B`) with
/// their human replies.
void _renderDigestPr(StringBuffer b, Map pr) {
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
