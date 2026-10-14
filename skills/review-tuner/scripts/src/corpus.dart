/// The corpus model shared by every script: one [PullRequest] per JSONL line,
/// with its [Comment]s, plus the rules that interpret them (substantive
/// comments, bot severity, human replies in bot threads). The line format is
/// documented in `references/formats.md`.
library;

import 'dart:convert';
import 'dart:io';

import 'cli.dart';

/// What kind of GitHub object a [Comment] came from.
enum CommentKind {
  /// An inline comment on a diff line, part of a review thread.
  inline,

  /// The body of a submitted review.
  review,

  /// A conversation comment on the PR.
  issue,
}

/// Matches comments too short or formulaic to carry review guidance.
final _trivialComment = RegExp(
  r'^\s*(lgtm|sgtm|thanks!?|thank you!?|ty|done\.?|fixed\.?|nice!?|\+1|👍|🎉|'
  r'/gemini review|@gemini-code-assist review)[.! ]*$',
  caseSensitive: false,
);

/// Shorter comments are never substantive.
const _substantiveLength = 20;

/// Heuristic: long enough and not formulaic.
bool isSubstantive(String body) =>
    body.trim().length >= _substantiveLength && !_trivialComment.hasMatch(body);

/// Severity badges in bot comment bodies (Gemini Code Assist's images).
const _severityBadges = {
  'critical.svg': 'critical',
  'high-priority.svg': 'high',
  'medium-priority.svg': 'medium',
  'low-priority.svg': 'low',
};

/// The severity a bot encoded in [body], or null if it has no known badge.
String? botSeverity(String body) => _severityBadges.entries
    .where((e) => body.contains(e.key))
    .firstOrNull
    ?.value;

/// A single human or bot comment on a pull request.
final class Comment {
  const Comment({
    required this.kind,
    required this.id,
    required this.author,
    required this.role,
    required this.weight,
    required this.isPrAuthor,
    required this.body,
    required this.createdAt,
    this.association,
    this.path,
    this.line,
    this.commitId,
    this.inReplyTo,
    this.threadId,
    this.reviewId,
    this.reviewState,
    this.resolved,
    this.outdated,
    this.severity,
  });

  /// Reads a corpus comment. Fields no longer written (e.g. `reactions`)
  /// are ignored; `severity` is derived from the body if absent.
  factory Comment.fromJson(Map<String, Object?> j) {
    var role = j['role'] as String;
    var body = j['body'] as String? ?? '';
    return Comment(
      kind: CommentKind.values.byName(j['kind'] as String),
      id: j['id'] as int,
      author: j['author'] as String,
      role: role,
      weight: (j['weight'] as num).toDouble(),
      association: j['authorAssociation'] as String?,
      isPrAuthor: j['isPrAuthor'] == true,
      body: body,
      createdAt: j['createdAt'] as String? ?? '',
      path: j['path'] as String?,
      line: j['line'] as int?,
      commitId: j['commitId'] as String?,
      inReplyTo: j['inReplyTo'] as int?,
      threadId: j['threadId'] as int?,
      reviewId: j['reviewId'] as int?,
      reviewState: j['reviewState'] as String?,
      resolved: j['threadResolved'] as bool?,
      outdated: j['threadOutdated'] as bool?,
      severity: j['severity'] as String? ??
          (role == 'bot' ? botSeverity(body) : null),
    );
  }

  final CommentKind kind;
  final int id;
  final String author;

  /// From the user config (see `Config.roleFor`); `bot` for bots and
  /// automation accounts, `agent` for AI agent accounts.
  final String role;
  final double weight;
  final String? association;
  final bool isPrAuthor;
  final String body;
  final String createdAt;
  final String? path;
  final int? line;

  /// The commit an inline comment was made on.
  final String? commitId;
  final int? inReplyTo;

  /// Id of the first comment in this comment's review thread (inline only).
  final int? threadId;
  final int? reviewId;
  final String? reviewState;
  final bool? resolved;
  final bool? outdated;

  /// Normalized severity of a bot comment ([botSeverity]); null if unknown.
  final String? severity;

  bool get isBot => role == 'bot';

  /// Agent accounts' own comments are not human evidence.
  bool get isHuman => !isBot && role != 'agent';

  /// The id of this comment's thread root (itself unless a reply).
  int get threadRoot => threadId ?? id;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'id': id,
        'author': author,
        'role': role,
        'weight': weight,
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
        if (severity != null) 'severity': severity,
      };
}

/// A file changed by a PR (its final state).
typedef PrFile = ({
  String path,
  int additions,
  int deletions,
  String changeType,
});

/// A pull request with all of its collected review activity.
final class PullRequest {
  const PullRequest({
    required this.number,
    required this.title,
    required this.url,
    required this.state,
    required this.isDraft,
    required this.createdAt,
    required this.closedAt,
    required this.mergedAt,
    required this.baseRefName,
    required this.baseRefOid,
    required this.headRefOid,
    required this.labels,
    required this.files,
    required this.author,
    required this.authorRole,
    required this.authorWeight,
    required this.association,
    required this.comments,
    this.truncated = const [],
    this.excludedReason,
  });

  /// Reads a corpus line. Fields no longer written (`commits`,
  /// `postReviewCommits`) are ignored.
  factory PullRequest.fromJson(Map<String, Object?> j) => PullRequest(
        number: j['number'] as int,
        title: j['title'] as String? ?? '',
        url: j['url'] as String?,
        state: j['state'] as String?,
        isDraft: j['isDraft'] == true,
        createdAt: j['createdAt'] as String?,
        closedAt: j['closedAt'] as String?,
        mergedAt: j['mergedAt'] as String?,
        baseRefName: j['baseRefName'] as String?,
        baseRefOid: j['baseRefOid'] as String?,
        headRefOid: j['headRefOid'] as String?,
        labels: [for (var l in j['labels'] as List? ?? const []) l as String],
        files: [
          for (var f in (j['files'] as List? ?? const []).cast<Map>())
            (
              path: f['path'] as String,
              additions: f['additions'] as int? ?? 0,
              deletions: f['deletions'] as int? ?? 0,
              changeType: f['changeType'] as String? ?? '',
            ),
        ],
        author: j['author'] as String,
        authorRole: j['authorRole'] as String,
        authorWeight: (j['authorWeight'] as num).toDouble(),
        association: j['authorAssociation'] as String?,
        comments: [
          for (var c in j['comments'] as List)
            Comment.fromJson(c as Map<String, Object?>),
        ],
        truncated: [for (var t in j['truncated'] as List? ?? const []) '$t'],
        excludedReason: j['excludedReason'] as String?,
      );

  final int number;
  final String title;
  final String? url;
  final String? state;
  final bool isDraft;
  final String? createdAt;
  final String? closedAt;
  final String? mergedAt;
  final String? baseRefName;
  final String? baseRefOid;
  final String? headRefOid;
  final List<String> labels;
  final List<PrFile> files;
  final String author;
  final String authorRole;
  final double authorWeight;
  final String? association;

  /// Sorted by `createdAt`.
  final List<Comment> comments;

  /// Connections that had more than one page (data beyond it is missing).
  final List<String> truncated;

  /// Set for automation PRs, which are kept but skipped by every summary.
  final String? excludedReason;

  bool get merged => mergedAt != null;
  bool get considered => excludedReason == null;

  /// Human comments not written by the PR author.
  Iterable<Comment> get reviewerComments =>
      comments.where((c) => c.isHuman && !c.isPrAuthor);

  /// Inline comments by [bot] that start a review thread.
  Iterable<Comment> botThreadRoots(String bot) => comments.where((c) =>
      c.author == bot && c.kind == CommentKind.inline && c.threadRoot == c.id);

  /// Human comments that follow [c] in its review thread.
  Iterable<Comment> humanReplies(Comment c) => comments.where((r) =>
      r.isHuman &&
      r.threadId != null &&
      r.threadId == c.threadRoot &&
      r.createdAt.compareTo(c.createdAt) > 0);

  /// `owner/name`, from [url].
  String? get slug =>
      RegExp(r'github\.com/([^/]+/[^/]+)/pull/').firstMatch('$url')?[1];

  /// Link to comment [c], or null if the PR has no URL.
  String? commentUrl(Comment c) => url == null
      ? null
      : switch (c.kind) {
          CommentKind.inline => '$url#discussion_r${c.id}',
          CommentKind.review => '$url#pullrequestreview-${c.id}',
          CommentKind.issue => '$url#issuecomment-${c.id}',
        };

  Map<String, Object?> toJson() => {
        'number': number,
        'title': title,
        'url': url,
        'state': state,
        'isDraft': isDraft,
        'createdAt': createdAt,
        'closedAt': closedAt,
        'mergedAt': mergedAt,
        'baseRefName': baseRefName,
        'baseRefOid': baseRefOid,
        'headRefOid': headRefOid,
        'labels': labels,
        'files': [
          for (var f in files)
            {
              'path': f.path,
              'additions': f.additions,
              'deletions': f.deletions,
              'changeType': f.changeType,
            },
        ],
        'author': author,
        'authorRole': authorRole,
        'authorWeight': authorWeight,
        if (association != null) 'authorAssociation': association,
        'outcome': merged ? 'merged' : 'closed-unmerged',
        if (excludedReason != null) 'excludedReason': excludedReason,
        'threadsTruncated': truncated.contains('reviewThreads') ||
            truncated.contains('threadComments'),
        if (truncated.isNotEmpty) 'truncated': truncated,
        'comments': [for (var c in comments) c.toJson()],
      };
}

/// Reads a corpus (one PR per line), exiting with [exitFailure] if it is
/// missing or any line is invalid.
List<PullRequest> readCorpus(String path) {
  var file = File(path);
  if (!file.existsSync()) fail('Missing corpus: $path');
  var prs = <PullRequest>[];
  var lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim().isEmpty) continue;
    try {
      prs.add(
          PullRequest.fromJson(jsonDecode(lines[i]) as Map<String, Object?>));
      // Deliberately broad: `fromJson` validates by casting, so a malformed
      // line surfaces as a FormatException, TypeError, or ArgumentError.
    } catch (e) {
      fail('Invalid corpus line ${i + 1} in $path: $e');
    }
  }
  return prs;
}

/// Writes [prs] as a corpus (one JSON object per line).
void writeCorpus(String path, List<PullRequest> prs) =>
    writeText(path, [for (var p in prs) '${jsonEncode(p.toJson())}\n'].join());
