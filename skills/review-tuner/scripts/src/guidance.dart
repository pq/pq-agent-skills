/// `collect.dart guidance`: a shallow clone of the target repo's default
/// branch at `<repoDir>/head/`, and a report of its agent files, harness
/// guidance files, and the relative links in them (propose mode's audit).
library;

import 'dart:io';

import 'agent_files.dart';
import 'cli.dart';
import 'config.dart';

/// Timeouts for cloning and for updating an existing clone.
const _cloneTimeout = Duration(minutes: 5);
const _fetchTimeout = Duration(minutes: 2);

/// Contribution docs listed when present (matched case-insensitively).
const _contributionDocs = [
  '.github/PULL_REQUEST_TEMPLATE.md',
  'PULL_REQUEST_TEMPLATE.md',
  'CONTRIBUTING.md',
  '.github/CONTRIBUTING.md',
];

final _inlineLink =
    RegExp(r'!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)');
final _referenceLink = RegExp(r'^\s{0,3}\[[^\]]+\]:\s*<?([^\s>]+)>?');
final _inlineCode = RegExp(r'`[^`\n]*`');
final _scheme = RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false);

/// Makes or updates `<repoDir>/head/` (a depth-1 clone of the default
/// branch). Returns its path.
Future<String> updateHead(Config config, RepoConfig repo) async {
  var head = '${config.repoDir(repo)}/head';
  if (Directory('$head/.git').existsSync()) {
    await git(head, ['fetch', '--quiet', '--depth', '1', 'origin', 'HEAD'],
        step: 'fetch ${repo.slug}', timeout: _fetchTimeout);
    await git(head, ['reset', '--quiet', '--hard', 'FETCH_HEAD'],
        step: 'reset $head', timeout: _fetchTimeout);
  } else {
    var dir = Directory(head);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    try {
      await gh(
          ['repo', 'clone', repo.slug, head, '--', '--quiet', '--depth', '1'],
          step: 'clone ${repo.slug}', timeout: _cloneTimeout, retries: 0);
    } on CommandException {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      rethrow;
    }
  }
  return head;
}

/// The guidance report for the clone at [head].
Map<String, Object?> guidanceReport(RepoConfig repo, String head) {
  var files = _files(head);
  var present = files.toSet();
  var lower = {for (var f in files) f.toLowerCase(): f};
  var agentFiles = [
    for (var f in files)
      if (agentRoot(f) != null) f
  ];
  var guidance = repo.harness.guidance;
  var markdown = {
    for (var f in [...agentFiles, ...guidance.where(present.contains)])
      if (f.endsWith('.md') || f.endsWith('.mdc')) f,
  }.toList()
    ..sort();
  var links = [for (var f in markdown) ..._links(head, f)];
  return {
    'repo': repo.slug,
    'head': head,
    'commit': _headCommit(head),
    'agentFiles': agentFiles,
    'agentRoots': {for (var f in agentFiles) agentRoot(f)}.toList(),
    'harnessGuidance': [
      for (var g in guidance) {'path': g, 'present': present.contains(g)},
    ],
    'contributionDocs': [
      for (var d in _contributionDocs)
        if (lower[d.toLowerCase()] case var f?) f,
    ],
    'linksChecked': links.length,
    'brokenLinks': [
      for (var l in links)
        if (!l.ok)
          {
            'file': l.file,
            'line': l.line,
            'target': l.target,
            'resolvesTo': l.resolvesTo,
          },
    ],
  };
}

String? _headCommit(String head) {
  var r = Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: head);
  return r.exitCode == 0 ? (r.stdout as String).trim() : null;
}

/// Repo-relative paths of every file under [head] (not `.git`), sorted.
List<String> _files(String head) => [
      for (var e
          in Directory(head).listSync(recursive: true, followLinks: false))
        if (e is File || e is Link)
          if (e.path.substring(head.length + 1) case var p
              when p != '.git' && !p.startsWith('.git/'))
            p,
    ]..sort();

typedef _Link = ({
  String file,
  int line,
  String target,
  String resolvesTo,
  bool ok,
});

/// Relative links in [file] (outside code spans and fenced blocks).
List<_Link> _links(String head, String file) {
  var lines = File('$head/$file').readAsLinesSync();
  var links = <_Link>[];
  var inFence = false;
  for (var (i, raw) in lines.indexed) {
    var isFence = raw.trimLeft().startsWith(RegExp('```|~~~'));
    if (isFence) inFence = !inFence;
    if (isFence || inFence) continue;
    var line = raw.replaceAll(_inlineCode, '');
    var targets = [
      for (var m in _inlineLink.allMatches(line)) m[1]!,
      if (_referenceLink.firstMatch(line) case var m?) m[1]!,
    ];
    for (var target in targets) {
      if (_scheme.hasMatch(target) || target.startsWith('#')) continue;
      var (:path, :escapes) = _resolve(file, target);
      var exists = !escapes &&
          (File('$head/$path').existsSync() ||
              Directory('$head/$path').existsSync());
      links.add((
        file: file,
        line: i + 1,
        target: target,
        resolvesTo: path,
        ok: exists,
      ));
    }
  }
  return links;
}

/// [target] resolved from [file]'s directory (or the repo root for `/...`),
/// and whether it escapes the repository.
({String path, bool escapes}) _resolve(String file, String target) {
  var path = target.split('#').first.split('?').first;
  try {
    path = Uri.decodeComponent(path);
  } on ArgumentError {
    // Keep the raw text; it won't exist.
  }
  var dir = file.contains('/') ? file.substring(0, file.lastIndexOf('/')) : '';
  var segments = <String>[];
  var escapes = false;
  var joined = path.startsWith('/') ? path : '$dir/$path';
  for (var s in joined.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s != '..') {
      segments.add(s);
    } else if (segments.isEmpty) {
      escapes = true;
    } else {
      segments.removeLast();
    }
  }
  return (path: segments.join('/'), escapes: escapes);
}

/// The report as markdown.
String renderGuidance(Map<String, Object?> r) {
  var b = StringBuffer()
    ..writeln('# Agent guidance: ${r['repo']}')
    ..writeln()
    ..writeln('Clone: `${r['head']}` at ${r['commit']} (default branch). '
        'Read files there instead of fetching them.');
  void list(String title, List<String> items, {String empty = '(none)'}) {
    b
      ..writeln()
      ..writeln('## $title')
      ..writeln();
    for (var item in items.isEmpty ? [empty] : items) {
      b.writeln('- $item');
    }
  }

  list('Harness guidance (what the bot reads)', [
    for (var g in (r['harnessGuidance'] as List).cast<Map>())
      '${g['path']}: ${g['present'] == true ? 'present' : 'MISSING'}',
  ]);
  list('Agent files', (r['agentFiles'] as List).cast<String>());
  list('Contribution docs', (r['contributionDocs'] as List).cast<String>());
  var broken = (r['brokenLinks'] as List).cast<Map>();
  list(
    'Broken relative links (${broken.length} of ${r['linksChecked']})',
    [
      for (var l in broken)
        '${l['file']}:${l['line']}: `${l['target']}` → `${l['resolvesTo']}` '
            '(missing)',
    ],
  );
  return b.toString();
}
