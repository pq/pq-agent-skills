/// Focused digest views for big corpora (`collect.dart digest --view`): the
/// reviewer bot's threads with human replies (`bot-replies`), substantive
/// inline and review-body comments by non-author humans (`human-inline`), and
/// `--max-bytes` / `--skip` paging of any view's markdown at PR boundaries.
/// Formats: `references/formats.md`.
library;

import 'dart:convert';

import 'cli.dart';
import 'config.dart';
import 'corpus.dart';

/// What `collect.dart digest --view` shows.
enum DigestView {
  full('full'),
  botReplies('bot-replies'),
  humanInline('human-inline');

  const DigestView(this.option);

  /// The `--view` value.
  final String option;

  /// The view named [option], or a usage error.
  static DigestView parse(String option) =>
      values.where((v) => v.option == option).firstOrNull ??
      usageError('--view must be one of '
          '${values.map((v) => v.option).join(', ')}.');
}

/// Human replies in bot threads keep this many times `--max-chars`, since
/// they carry the verdict on the bot's comment.
const replyCharsFactor = 3;

/// Characters of a commit SHA shown in markdown.
const _shaPrefixLength = 10;

/// A leading severity badge in a flattened bot comment (`[medium] ...`).
final _leadingBadge = RegExp(r'^\[[^\]]*\]\s*');

/// `author [role weight]`, marking the PR's author.
String whoLabel(Map c) {
  var author =
      c['isPrAuthor'] == true ? '${c['author']} (PR author)' : c['author'];
  return '$author [${c['role']} ${c['weight']}]';
}

/// Location of [c]: `path:line` (plus `@<commit>` when known), or its kind.
String whereLabel(Map c) {
  if (c['path'] == null) return c['kind'] as String;
  var line = c['line'] == null ? '' : ':${c['line']}';
  var commit = c['commitId'] is String
      ? ' @${(c['commitId'] as String).substring(0, _shaPrefixLength)}'
      : '';
  return '`${c['path']}$line`$commit';
}

/// `#N title (author, role, outcome)`.
String prLabel(Map pr) => '#${pr['number']} ${pr['title']} '
    '(${pr['author']}, ${pr['authorRole']}, ${pr['outcome']})';

Map<String, Object?> _prHeader(PullRequest pr) => {
      'number': pr.number,
      'title': pr.title,
      'author': pr.author,
      'authorRole': pr.authorRole,
      'outcome': pr.merged ? 'merged' : 'closed-unmerged',
    };

/// A comment in a view: ids and links so it can be cited or passed to
/// `--rebuttals`.
Map<String, Object?> _viewComment(PullRequest pr, Comment c, int max) => {
      'id': c.id,
      'kind': c.kind.name,
      'author': c.author,
      'role': c.role,
      'weight': c.weight,
      if (c.isPrAuthor) 'isPrAuthor': true,
      if (c.path != null) 'path': c.path,
      if (c.line != null) 'line': c.line,
      if (c.commitId != null) 'commitId': c.commitId,
      if (c.reviewState != null) 'reviewState': c.reviewState,
      'text': excerpt(c.body, max),
      if (pr.commentUrl(c) case var url?) 'url': url,
    };

/// Fields every view shares.
Map<String, Object?> _viewInfo(DigestView view, List<PullRequest> corpus,
        RepoConfig repo, String corpusPath, int maxChars) =>
    {
      'view': view.option,
      'repo': repo.slug,
      'corpus': corpusPath,
      'bot': repo.bot,
      'maxChars': maxChars,
      'prsInCorpus': corpus.length,
      'prsSkippedAutomation': corpus.where((p) => !p.considered).length,
    };

// ---------------------------------------------------------------------------
// bot-replies
// ---------------------------------------------------------------------------

/// The reviewer bot's inline threads with at least one human reply, by PR.
/// With [noAcks], threads whose human replies are all bare acknowledgments
/// ([isAcknowledgment]) are dropped and listed in `droppedThreads`.
Map<String, Object?> buildBotReplies(
    List<PullRequest> corpus, RepoConfig repo, String corpusPath, int maxChars,
    {required bool noAcks}) {
  var threads = 0;
  var replied = 0;
  var dropped = <Map<String, Object?>>[];
  var prs = <Map<String, Object?>>[];
  for (var pr in corpus.where((p) => p.considered)) {
    var shown = <Map<String, Object?>>[];
    for (var root in pr.botThreadRoots(repo.bot)) {
      threads++;
      var replies = pr.humanReplies(root).toList();
      if (replies.isEmpty) continue;
      replied++;
      if (noAcks && replies.every((r) => isAcknowledgment(r.body))) {
        dropped.add({
          'pr': pr.number,
          'id': root.id,
          'replies': [for (var r in replies) r.id],
        });
        continue;
      }
      shown.add(_botThread(pr, root, replies, maxChars));
    }
    if (shown.isNotEmpty) prs.add({..._prHeader(pr), 'threads': shown});
  }
  var shownThreads = [for (var p in prs) ...p['threads'] as List<Map>];
  return {
    ..._viewInfo(DigestView.botReplies, corpus, repo, corpusPath, maxChars),
    'noAcks': noAcks,
    'botThreads': threads,
    'botThreadsWithHumanReply': replied,
    if (noAcks) 'ackThreadsDropped': dropped.length,
    'threadsShown': shownThreads.length,
    'repliesShown':
        shownThreads.fold<int>(0, (n, t) => n + (t['replies'] as List).length),
    'prsShown': prs.length,
    'prs': prs,
    if (noAcks) 'droppedThreads': dropped,
  };
}

Map<String, Object?> _botThread(
        PullRequest pr, Comment root, List<Comment> replies, int maxChars) =>
    {
      'id': root.id,
      if (root.path != null) 'path': root.path,
      if (root.line != null) 'line': root.line,
      if (root.commitId != null) 'commitId': root.commitId,
      if (root.severity != null) 'severity': root.severity,
      'resolved': root.resolved == true,
      'outdated': root.outdated == true,
      'text': excerpt(_withoutBadge(root), maxChars),
      if (pr.commentUrl(root) case var url?) 'url': url,
      'replies': [
        for (var r in replies)
          {
            ..._viewComment(pr, r, maxChars * replyCharsFactor),
            'isPrAuthor': r.isPrAuthor,
            if (isAcknowledgment(r.body)) 'ack': true,
          },
      ],
    };

/// [c]'s flattened body without its leading severity badge, which the view
/// shows as `severity`.
String _withoutBadge(Comment c) {
  var text = flatten(c.body);
  return c.severity == null ? text : text.replaceFirst(_leadingBadge, '');
}

/// The `bot-replies` summary paragraph.
String botRepliesHeader(Map<String, Object?> d) {
  var dropped = switch (d['ackThreadsDropped']) {
    int n => ', $n dropped as bare acknowledgments (--no-acks)',
    _ => '',
  };
  return 'Corpus: ${d['corpus']} (${d['prsInCorpus']} PRs, '
      '${d['prsSkippedAutomation']} automation skipped). Bot: ${d['bot']}: '
      '${d['botThreads']} inline threads, ${d['botThreadsWithHumanReply']} '
      'with human replies$dropped. Shown: ${d['threadsShown']} threads, '
      '${d['repliesShown']} replies, in ${d['prsShown']} PRs.';
}

/// Markdown for the `bot-replies` view [d], showing [prs] (a slice of
/// `d['prs']`).
String renderBotReplies(Map<String, Object?> d, List<Map> prs) {
  var max = d['maxChars'] as int;
  var b = StringBuffer()
    ..writeln('# Bot threads with human replies: ${d['repo']}')
    ..writeln()
    ..writeln('${botRepliesHeader(d)} Bot text truncated to $max chars, '
        'replies to ${max * replyCharsFactor}. `[b:<id>]` is the bot '
        'comment, `[r:<id>]` a human reply (ids for --rebuttals); `[ack]` '
        'marks a bare acknowledgment.')
    ..writeln()
    ..writeln('## PRs');
  for (var pr in prs) {
    b
      ..writeln()
      ..writeln('### ${prLabel(pr)}');
    for (var t in (pr['threads'] as List).cast<Map>()) {
      var state = [
        if (t['severity'] case String severity) severity,
        t['resolved'] == true ? 'resolved' : 'unresolved',
        if (t['outdated'] == true) 'outdated',
      ].join(', ');
      b.writeln('- [b:${t['id']}] ${whereLabel({...t, 'kind': 'inline'})} '
          '[$state]: ${t['text']}');
      for (var r in (t['replies'] as List).cast<Map>()) {
        var ack = r['ack'] == true ? ' [ack]' : '';
        b.writeln('  - ↳ [r:${r['id']}] ${whoLabel(r)}$ack: ${r['text']}');
      }
    }
  }
  return b.toString();
}

// ---------------------------------------------------------------------------
// human-inline
// ---------------------------------------------------------------------------

/// Substantive inline and review-body comments by humans other than the PR
/// author, by PR. Replies in the reviewer bot's threads (`bot-replies`) and
/// conversation comments are left out.
Map<String, Object?> buildHumanInline(List<PullRequest> corpus, RepoConfig repo,
    String corpusPath, int maxChars) {
  var prs = [
    for (var pr in corpus.where((p) => p.considered))
      if (_humanInline(pr, repo.bot, maxChars) case var comments
          when comments.isNotEmpty)
        {..._prHeader(pr), 'comments': comments},
  ];
  var comments = [for (var p in prs) ...p['comments'] as List<Map>];
  var byRole = <String, ({int comments, double weight})>{};
  for (var c in comments) {
    var r = byRole[c['role']] ?? (comments: 0, weight: 0.0);
    byRole[c['role'] as String] = (
      comments: r.comments + 1,
      weight: r.weight + (c['weight'] as num).toDouble(),
    );
  }
  return {
    ..._viewInfo(DigestView.humanInline, corpus, repo, corpusPath, maxChars),
    'comments': comments.length,
    'inline': comments.where((c) => c['kind'] == 'inline').length,
    'reviewBodies': comments.where((c) => c['kind'] == 'review').length,
    'weighted': comments.fold<double>(
        0, (sum, c) => sum + (c['weight'] as num).toDouble()),
    'byRole': {
      for (var MapEntry(:key, :value) in byRole.entries)
        key: {'comments': value.comments, 'weight': value.weight},
    },
    'paths': {for (var c in comments) c['path']}.whereType<String>().length,
    'prsShown': prs.length,
    'prs': prs,
  };
}

List<Map<String, Object?>> _humanInline(
    PullRequest pr, String bot, int maxChars) {
  var botRoots = {for (var r in pr.botThreadRoots(bot)) r.id};
  return [
    for (var c in pr.reviewerComments)
      if (c.kind != CommentKind.issue &&
          !botRoots.contains(c.threadId) &&
          isSubstantive(c.body))
        _viewComment(pr, c, maxChars),
  ];
}

/// The `human-inline` summary paragraph.
String humanInlineHeader(Map<String, Object?> d) =>
    'Corpus: ${d['corpus']} (${d['prsInCorpus']} PRs, '
    '${d['prsSkippedAutomation']} automation skipped). Substantive comments '
    'by humans other than the PR author: ${d['comments']} (weighted '
    '${(d['weighted'] as num).toStringAsFixed(1)}; ${d['inline']} inline on '
    '${d['paths']} paths, ${d['reviewBodies']} review bodies) in '
    '${d['prsShown']} PRs.';

/// Markdown for the `human-inline` view [d], showing [prs] (a slice of
/// `d['prs']`) grouped by path (most comments first), then PR.
String renderHumanInline(Map<String, Object?> d, List<Map> prs) {
  var b = StringBuffer()
    ..writeln('# Human review comments by path: ${d['repo']}')
    ..writeln()
    ..writeln('${humanInlineHeader(d)} Replies in bot threads are in '
        '`--view bot-replies`; conversation comments are left out. Text '
        'truncated to ${d['maxChars']} chars; `[c:<id>]` is the comment id.')
    ..writeln()
    ..writeln('## PRs')
    ..writeln();
  var byPath = <String?, List<(Map, Map)>>{};
  for (var pr in prs) {
    b.writeln('- ${prLabel(pr)}');
    for (var c in (pr['comments'] as List).cast<Map>()) {
      byPath.putIfAbsent(c['path'] as String?, () => []).add((pr, c));
    }
  }
  var paths = byPath.keys.whereType<String>().toList()
    ..sort((a, b) => switch (byPath[b]!.length.compareTo(byPath[a]!.length)) {
          0 => a.compareTo(b),
          var order => order,
        });
  for (var path in paths) {
    b
      ..writeln()
      ..writeln('## `$path` (${byPath[path]!.length})')
      ..writeln();
    for (var (pr, c) in byPath[path]!) {
      var line = c['line'] == null ? '' : ' L${c['line']}';
      b.writeln('- #${pr['number']}$line [c:${c['id']}] ${whoLabel(c)}: '
          '${c['text']}');
    }
  }
  if (byPath[null] case var reviews?) {
    b
      ..writeln()
      ..writeln('## Review bodies (${reviews.length})')
      ..writeln();
    for (var (pr, c) in reviews) {
      var state = c['reviewState'] == null ? '' : ' (${c['reviewState']})';
      b.writeln('- #${pr['number']} [c:${c['id']}] ${whoLabel(c)}$state: '
          '${c['text']}');
    }
  }
  return b.toString();
}

// ---------------------------------------------------------------------------
// Paging
// ---------------------------------------------------------------------------

/// One page of a view's markdown: PRs [from] (exclusive) to [to] (inclusive,
/// 1-based) of [total].
typedef Page = ({String markdown, int from, int to, int total});

/// Renders [prs] from index [skip] with [render]. With [maxBytes], keeps as
/// many PRs as fit in that many UTF-8 bytes (always at least one) and ends
/// with a footer naming the next `--skip`; with [skip] alone, all the rest.
Page paginate(List<Map> prs, String Function(List<Map>) render,
    {int? maxBytes, int skip = 0}) {
  var total = prs.length;
  if (skip > 0 && skip >= total) {
    usageError('--skip $skip is past the last PR ($total in this view).');
  }
  var paged = maxBytes != null || skip > 0;
  String page(int to) {
    var md = render(prs.sublist(skip, to));
    return paged ? '$md${pageFooter(skip, to, total, maxBytes)}' : md;
  }

  var to = total;
  if (maxBytes != null && _bytes(page(to)) > maxBytes) {
    // The largest `to` whose page fits; at least one PR per page.
    var lo = skip + 1;
    var hi = total - 1;
    while (lo < hi) {
      var mid = (lo + hi + 1) ~/ 2;
      if (_bytes(page(mid)) <= maxBytes) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    to = lo;
  }
  return (markdown: page(to), from: skip, to: to, total: total);
}

/// The paging line ending a page, without the leading rule.
String pageStatus(int from, int to, int total, int? maxBytes) {
  if (total == 0) return 'No PRs in this view.';
  var budget = maxBytes == null ? '' : ' (budget $maxBytes bytes)';
  var next = to < total ? 'Next page: --skip $to' : 'Last page.';
  return 'Showing PRs ${from + 1}–$to of $total$budget. $next';
}

String pageFooter(int from, int to, int total, int? maxBytes) =>
    '\n---\n\n${pageStatus(from, to, total, maxBytes)}\n';

int _bytes(String s) => utf8.encode(s).length;
