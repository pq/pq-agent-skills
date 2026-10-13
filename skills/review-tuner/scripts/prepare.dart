/// Prepares review-tuner evaluations: scaffolds an eval, builds blinded
/// reviewer task manifests, and builds blind judge tasks.
///
/// See `references/formats.md` for the data layout and every file format.
///
/// Usage:
///
///   dart run prepare.dart init --repo <owner/name|alias> --id <id>
///       [--config <path>]
///     Creates `<repoDir>/evals/<id>/` with `arms/baseline/` and
///     `arms/candidate/` holding the harness guidance files from the default
///     branch, plus a starter `eval.json`. Refuses to overwrite.
///
///   dart run prepare.dart check --eval <evalDir> [--out <dir>] [--seed <n>]
///       [--config <path>]
///     Quick mode (default out `<evalDir>/check`): per-case PR diffs fetched
///     from GitHub (no clone), blinded arms, and `tasks.json`. Reviewers get
///     no repository checkout.
///
///   dart run prepare.dart evaluate --eval <evalDir> [--out <dir>]
///       [--seed <n>] [--config <path>]
///     Thorough mode (default out `<evalDir>/evaluate`): as `check`, plus a
///     detached worktree per case (from `<repoDir>/repo`) with the PR applied
///     as uncommitted changes and all agent files removed.
///
///   dart run prepare.dart judge --run <runDir> [--seed <n>]
///     Pools kept findings (severity >= medium) per case across all arms,
///     models, and runs, shuffles them (seed default 42), and writes
///     `judge/<case>.findings.json` and `judge/tasks.json`.
///
/// `--seed` for `check`/`evaluate` fixes the random arm assignment (default:
/// the current time). No reviewer or judge is run and no result file is
/// written: the orchestrator sends each task's `prompt` to a fresh agent.
///
/// Exit codes: 0 success, 1 a case or step failed (failures are always
/// listed, never skipped silently), 2 bad arguments.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'src/config.dart';
import 'src/eval.dart';

const usage = '''
Usage:
  dart run prepare.dart init --repo <owner/name|alias> --id <id> [--config <path>]
  dart run prepare.dart check --eval <evalDir> [--out <dir>] [--seed <n>] [--config <path>]
  dart run prepare.dart evaluate --eval <evalDir> [--out <dir>] [--seed <n>] [--config <path>]
  dart run prepare.dart judge --run <runDir> [--seed <n>]''';

/// Agent instruction paths removed from evaluate worktrees (in addition to
/// the harness guidance paths) so reviewers only see the arm's guidance.
const strippedPaths = [
  '.gemini',
  '.agents',
  '.aiconfig',
  'AGENTS.md',
  'GEMINI.md',
  'CLAUDE.md',
];

/// REPO value given to reviewers in check mode.
const noRepo = 'none (diff-only review)';

const arms = ['arm1', 'arm2'];

/// The skill directory (this script lives in `<skill>/scripts/`).
final skillDir = File(Platform.script.toFilePath()).parent.parent.path;

/// Thrown when an external step (git, gh) or a precondition fails.
final class StepException implements Exception {
  StepException(this.step, this.message);

  final String step;
  final String message;

  @override
  String toString() => '$step: $message';
}

Future<void> main(List<String> argv) async {
  var args = parseArgs(argv);
  if (args.positional.length != 1) usageError(usage);
  var options = args.options;
  switch (args.positional.single) {
    case 'init':
      await init(options);
    case 'check':
      await prepare(options, thorough: false);
    case 'evaluate':
      await prepare(options, thorough: true);
    case 'judge':
      judge(options);
    default:
      usageError(usage);
  }
}

// ---------------------------------------------------------------- helpers

String need(Map<String, String> options, String name) =>
    options[name] ?? usageError('Missing --$name\n$usage');

int? intOption(Map<String, String> options, String name) {
  var value = options[name];
  if (value == null) return null;
  return int.tryParse(value) ?? usageError('--$name must be an integer');
}

/// Absolute, normalized path without a trailing slash.
String absPath(String path) {
  var p = File(path).absolute.uri.normalizePath().toFilePath();
  return p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;
}

Never fail(String message) {
  stderr.writeln(message);
  exit(exitFailure);
}

void writeText(String path, String text) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
}

Future<String> run(String exe, List<String> args,
    {String? cwd, String? step}) async {
  var result = await Process.run(exe, args,
      workingDirectory: cwd, stdoutEncoding: utf8, stderrEncoding: utf8);
  if (result.exitCode != 0) {
    throw StepException(
        step ?? '$exe ${args.first}', (result.stderr as String).trim());
  }
  return result.stdout as String;
}

Future<String> gh(List<String> args, {String? step}) =>
    run('gh', args, step: step);

Future<String> git(String dir, List<String> args, {String? step}) =>
    run('git', args, cwd: dir, step: step);

/// Repo-relative paths of all files under [dir], sorted.
List<String> listFiles(String dir) {
  if (!Directory(dir).existsSync()) return [];
  return [
    for (var f in Directory(dir).listSync(recursive: true).whereType<File>())
      f.path.substring(dir.length + 1),
  ]..sort();
}

void copyTree(String from, String to) {
  for (var rel in listFiles(from)) {
    File('$to/$rel').parent.createSync(recursive: true);
    File('$from/$rel').copySync('$to/$rel');
  }
}

void deletePath(String path) {
  switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    case FileSystemEntityType.directory:
      Directory(path).deleteSync(recursive: true);
    case FileSystemEntityType.notFound:
      break;
    default:
      File(path).deleteSync();
  }
}

String fill(String template, Map<String, String> values) {
  var text = template;
  for (var MapEntry(:key, :value) in values.entries) {
    text = text.replaceAll('{{$key}}', value);
  }
  return text;
}

String readPrompt(String name) =>
    File('$skillDir/prompts/$name.md').readAsStringSync();

/// Refuses to overwrite outputs of an earlier preparation: re-randomizing
/// arms or re-pooling findings would silently invalidate them.
void refuseExisting(String dir, String suffix, String what) {
  var stale = listFiles(dir).where((f) => f.endsWith(suffix)).toList();
  if (stale.isNotEmpty) {
    fail('$dir already has ${stale.length} $what (e.g. ${stale.first}). '
        'Use a different --out or delete them first.');
  }
}

Future<String> defaultBranch(RepoConfig repo) async =>
    (await gh(['api', 'repos/${repo.slug}', '--jq', '.default_branch'],
            step: 'default branch'))
        .trim();

// ------------------------------------------------------------------- init

Future<void> init(Map<String, String> options) async {
  var config = loadConfig(path: options['config']);
  var repo = config.repo(need(options, 'repo'));
  var id = need(options, 'id');
  var evalDir = '${config.repoDir(repo)}/evals/$id';
  if (FileSystemEntity.typeSync(evalDir) != FileSystemEntityType.notFound) {
    fail('$evalDir already exists; refusing to overwrite.');
  }
  var files = <String, String>{};
  for (var path in repo.harness.guidance) {
    try {
      files[path] = await gh([
        'api',
        '-H',
        'Accept: application/vnd.github.raw',
        'repos/${repo.slug}/contents/$path',
      ], step: 'fetch $path');
    } on StepException catch (e) {
      if (!e.message.contains('404')) fail('$e');
    }
  }
  for (var MapEntry(:key, :value) in files.entries) {
    writeText('$evalDir/arms/baseline/$key', value);
    writeText('$evalDir/arms/candidate/$key', value);
  }
  Directory('$evalDir/arms/candidate').createSync(recursive: true);
  writeJson('$evalDir/eval.json', starterEval(repo, id));
  printInitSummary(evalDir, repo, files.keys.toList());
}

Map<String, Object?> starterEval(RepoConfig repo, String id) => {
      'id': id,
      'repo': repo.slug,
      'type': 'edit',
      'affects': 'bot',
      'models': [
        {'tier': 'inherit', 'runs': 1},
      ],
      'concern': {
        'cite': 'TODO: regex citing the guidance rule',
        'objection': 'TODO: optional regex for the objection wording',
        'minSeverity': 'high',
        'tags': <String>[],
      },
      'cases': <Object?>[],
    };

void printInitSummary(String evalDir, RepoConfig repo, List<String> fetched) {
  var absent = repo.harness.guidance.where((p) => !fetched.contains(p));
  stdout.writeln('''
## Created eval `$evalDir`

- Guidance fetched from the default branch of ${repo.slug}: ${fetched.isEmpty ? 'none' : fetched.map((p) => '`$p`').join(', ')}
- Not on the default branch: ${absent.isEmpty ? 'none' : absent.map((p) => '`$p`').join(', ')}

Next steps:
1. Edit the guidance under `arms/candidate/` (to add a file that does not
   exist yet, create it there and set `"type": "add"`).
2. Fill in `eval.json`: `concern`, `pathGroups`, and `cases` (real PRs need
   `pr` + the reviewed `commit`; synthetic cases need `patch`).
3. Run `dart run $skillDir/scripts/prepare.dart check --eval $evalDir`.''');
}

// --------------------------------------------------------- check/evaluate

Future<void> prepare(Map<String, String> options,
    {required bool thorough}) async {
  var evalDir = absPath(need(options, 'eval'));
  var eval = loadEval(evalDir);
  var config = loadConfig(path: options['config']);
  var repo = config.repo(eval.repo);
  var mode = thorough ? 'evaluate' : 'check';
  var out = absPath(options['out'] ?? '$evalDir/$mode');
  var seed =
      intOption(options, 'seed') ?? DateTime.now().microsecondsSinceEpoch;
  refuseExisting('$out/results', '.json', 'result files');
  File('$out/tasks.json').parent.createSync(recursive: true);
  deletePath('$out/tasks.json');

  var assignment = writeArms(evalDir, out, eval, repo, Random(seed));
  var branch = await defaultBranch(repo);
  var clone = thorough ? await ensureClone(config, repo, branch) : null;
  var repoText = <String, String>{};
  var failures = <String, String>{};
  for (var c in eval.cases) {
    try {
      var caseDir = '$out/work/cases/${c.id}';
      var base = await writeDiff(c, evalDir, caseDir, repo, branch);
      repoText[c.id] = clone == null
          ? noRepo
          : '`${await makeWorktree(clone, c, caseDir, base, branch, repo)}`';
    } on Object catch (e) {
      failures[c.id] = '$e';
    }
  }
  printCases(eval, out, repoText, failures);
  if (failures.isNotEmpty) {
    fail('\n${failures.length} case(s) failed; tasks.json was not written.');
  }
  var tasks = buildTasks(eval, out, repoText);
  writePromptFiles('$out/prompts', tasks);
  writeJson('$out/tasks.json', {
    'eval': eval.id,
    'evalDir': evalDir,
    'mode': mode,
    'seed': seed,
    'arms': assignment,
    'tasks': tasks,
  });
  printNextSteps(eval, out, tasks, seed);
}

/// Writes each task's prompt to `<dir>/<id>.md` and adds `promptFile` plus a
/// one-line `message` the orchestrator can send verbatim, so reviewers never
/// need to see `tasks.json` (which holds the arm mapping).
void writePromptFiles(String dir, List<Map<String, Object?>> tasks) {
  Directory(dir).createSync(recursive: true);
  for (var t in tasks) {
    var path = '$dir/${t['id']}.md';
    File(path).writeAsStringSync(t['prompt'] as String);
    t['promptFile'] = path;
    t['message'] = 'Read $path and follow its instructions exactly.';
  }
}

/// Materializes the blinded arms under `<out>/work/arms/` and returns the
/// neutral-name assignment (e.g. `{arm1: candidate, arm2: baseline}`).
Map<String, String> writeArms(
    String evalDir, String out, Eval eval, RepoConfig repo, Random rng) {
  var baseline = '$evalDir/arms/baseline';
  var present = listFiles(baseline);
  var missing = repo.harness.guidance.where((p) => !present.contains(p));
  if (eval.type != 'add' && missing.isNotEmpty) {
    fail('Missing baseline guidance in $baseline: ${missing.join(', ')}\n'
        '(set "type": "add" if the candidate adds a new file).');
  }
  var candidateFirst = rng.nextBool();
  var assignment = {
    'arm1': candidateFirst ? 'candidate' : 'baseline',
    'arm2': candidateFirst ? 'baseline' : 'candidate',
  };
  deletePath('$out/work/arms');
  for (var MapEntry(:key, :value) in assignment.entries) {
    var dir = '$out/work/arms/$key';
    Directory(dir).createSync(recursive: true);
    copyTree(baseline, dir);
    if (value == 'candidate') copyTree('$evalDir/arms/candidate', dir);
  }
  if (sameTree('$out/work/arms/arm1', '$out/work/arms/arm2')) {
    stderr.writeln('Warning: candidate guidance is identical to baseline.');
  }
  return assignment;
}

bool sameTree(String a, String b) {
  var files = listFiles(a);
  if (files.join('\n') != listFiles(b).join('\n')) return false;
  return files.every((f) =>
      File('$a/$f').readAsStringSync() == File('$b/$f').readAsStringSync());
}

/// Writes `<caseDir>/diff.patch`. For a PR this is the diff GitHub showed at
/// the reviewed commit (`merge-base(default, commit)...commit`), fetched
/// without a clone; returns the merge base. Synthetic cases copy the patch.
Future<String?> writeDiff(EvalCase c, String evalDir, String caseDir,
    RepoConfig repo, String branch) async {
  var target = '$caseDir/diff.patch';
  Directory(caseDir).createSync(recursive: true);
  if (c.patch case var patch?) {
    File('$evalDir/$patch').copySync(target);
    return null;
  }
  var base = (await gh([
    'api',
    'repos/${repo.slug}/compare/$branch...${c.commit}',
    '--jq',
    '.merge_base_commit.sha',
  ], step: 'merge base'))
      .trim();
  var diff = await gh([
    'api',
    '-H',
    'Accept: application/vnd.github.diff',
    'repos/${repo.slug}/compare/$base...${c.commit}',
  ], step: 'fetch diff');
  if (diff.trim().isEmpty) throw StepException('fetch diff', 'empty diff');
  File(target).writeAsStringSync(diff);
  return base;
}

/// Returns the clone at `<repoDir>/repo`, cloning it if missing, with the
/// default branch fetched.
Future<String> ensureClone(
    Config config, RepoConfig repo, String branch) async {
  var clone = '${config.repoDir(repo)}/repo';
  if (!Directory(clone).existsSync()) {
    Directory(clone).parent.createSync(recursive: true);
    await gh(['repo', 'clone', repo.slug, clone, '--', '--quiet'],
        step: 'clone');
  }
  await git(clone, ['fetch', '--quiet', 'origin', branch],
      step: 'fetch $branch');
  return clone;
}

/// The reviewed commit may predate a force-push, so fetch it by SHA if the
/// PR head fetch did not bring it in.
Future<void> ensureCommit(String clone, String sha) async {
  try {
    await git(clone, ['cat-file', '-e', '$sha^{commit}']);
  } on StepException {
    await git(clone, ['fetch', '--quiet', 'origin', sha],
        step: 'fetch commit $sha');
  }
}

/// Creates `<caseDir>/repo`: a detached worktree whose HEAD is the merge base
/// and whose working tree has the case's changes uncommitted, with all agent
/// files removed. Returns its path.
Future<String> makeWorktree(String clone, EvalCase c, String caseDir,
    String? base, String branch, RepoConfig repo) async {
  var tree = '$caseDir/repo';
  deletePath(tree);
  await git(clone, ['worktree', 'prune']);
  if (c.pr case var pr? when !c.synthetic) {
    await git(
        clone,
        [
          'fetch',
          '--quiet',
          'origin',
          '+refs/pull/$pr/head:refs/review-tuner/pr$pr',
        ],
        step: 'fetch PR head');
  }
  if (c.commit case var sha?) await ensureCommit(clone, sha);
  var start = c.commit ?? 'origin/$branch';
  await git(clone, ['worktree', 'add', '--detach', '--quiet', tree, start],
      step: 'worktree add');
  if (c.synthetic) {
    await git(tree, ['apply', '--whitespace=nowarn', '$caseDir/diff.patch'],
        step: 'apply patch');
  } else {
    // Working tree keeps the reviewed commit; HEAD and index move to the
    // merge base, leaving exactly the PR's changes uncommitted.
    await git(tree, ['reset', '--quiet', base!], step: 'reset to merge base');
  }
  for (var path in [...strippedPaths, ...repo.harness.guidance]) {
    deletePath('$tree/$path');
  }
  return tree;
}

List<Map<String, Object?>> buildTasks(
    Eval eval, String out, Map<String, String> repoText) {
  var template = readPrompt('reviewer');
  var guidance = {for (var arm in arms) arm: guidanceBullets(out, arm)};
  return [
    for (var m in eval.models)
      for (var c in eval.cases)
        for (var arm in arms)
          for (var run = 1; run <= m.runs; run++)
            reviewerTask(template, out, c.id, arm, m, run, guidance[arm]!,
                repoText[c.id]!),
  ];
}

Map<String, Object?> reviewerTask(
    String template,
    String out,
    String caseId,
    String arm,
    ({String tier, int runs, String label}) model,
    int run,
    String guidance,
    String repo) {
  var output = '$out/results/${model.label}/$caseId-$arm-r$run.json';
  return {
    'id': '$caseId-$arm-${model.label}-r$run',
    'case': caseId,
    'arm': arm,
    'model': model.label,
    'tier': model.tier,
    'run': run,
    'output': output,
    'prompt': fill(template, {
      'GUIDANCE': guidance,
      'DIFF': '$out/work/cases/$caseId/diff.patch',
      'REPO': repo,
      'OUTPUT': output,
    }),
  };
}

String guidanceBullets(String out, String arm) {
  var dir = '$out/work/arms/$arm';
  return [for (var rel in listFiles(dir)) '  - $rel: $dir/$rel'].join('\n');
}

void printCases(Eval eval, String out, Map<String, String> repoText,
    Map<String, String> failures) {
  stdout
    ..writeln('## review-tuner prepare: ${eval.id}\n')
    ..writeln('| Case | Source | Diff bytes | Repo |')
    ..writeln('|---|---|---|---|');
  for (var c in eval.cases) {
    var source = c.synthetic ? 'patch `${c.patch}`' : 'PR #${c.pr}';
    if (failures[c.id] case var error?) {
      stdout.writeln('| ${c.id} | $source | FAILED | $error |');
      continue;
    }
    var bytes = File('$out/work/cases/${c.id}/diff.patch').lengthSync();
    stdout.writeln('| ${c.id} | $source | $bytes | ${repoText[c.id]} |');
  }
}

void printNextSteps(
    Eval eval, String out, List<Map<String, Object?>> tasks, int seed) {
  var perModel = <String, int>{};
  for (var t in tasks) {
    perModel.update(t['model'] as String, (n) => n + 1, ifAbsent: () => 1);
  }
  var counts = perModel.entries.map((e) => '`${e.key}`: ${e.value}');
  stdout.writeln('''

- Cases prepared: ${eval.cases.length}
- Tasks: ${tasks.length} (${counts.join(', ')})
- Manifest: `$out/tasks.json` (arm seed $seed)

**Next:** for each task in `$out/tasks.json`, send its one-line `message` to a fresh, independent reviewer on its `tier`, in batches of at most 10, then run `dart run $skillDir/scripts/score.dart validate --run $out`.''');
}

// ------------------------------------------------------------------ judge

/// One kept finding and where it came from.
typedef Pooled = ({
  Map<String, Object?> comment,
  String arm,
  String model,
  int run,
});

void judge(Map<String, String> options) {
  var runDir = absPath(need(options, 'run'));
  var seed = intOption(options, 'seed') ?? 42;
  var manifest = readJson('$runDir/tasks.json') as Map<String, Object?>;
  var evalDir = manifest['evalDir'] as String? ?? File(runDir).parent.path;
  var eval = loadEval(evalDir);
  var judgeDir = '$runDir/judge';
  refuseExisting(judgeDir, '.verdicts.json', 'verdict files');
  if (!Directory('$runDir/results').existsSync()) {
    fail('No results directory: $runDir/results');
  }

  var skipped = <String>[];
  var errors = <String>[];
  var pooled = poolFindings(runDir, eval, skipped, errors);
  if (errors.isNotEmpty) {
    fail('Unusable result files (nothing written):\n'
        '${errors.map((e) => '- $e').join('\n')}');
  }
  var template = readPrompt('judge');
  var mapping = <String, Object?>{};
  var tasks = <Map<String, Object?>>[];
  var counts = <String, int>{};
  for (var c in eval.cases) {
    var findings = pooled[c.id] ?? <Pooled>[];
    findings.shuffle(Random(seed));
    var visible = [
      for (var p in findings) assignId(p, c.id, mapping),
    ];
    writeJson('$judgeDir/${c.id}.findings.json', visible);
    counts[c.id] = visible.length;
    if (visible.isNotEmpty) tasks.add(judgeTask(template, runDir, c, eval));
  }
  writePromptFiles('$judgeDir/prompts', tasks);
  writeJson('$judgeDir/tasks.json', {
    'eval': eval.id,
    'mode': 'judge',
    'seed': seed,
    'arms': manifest['arms'],
    'mapping': mapping,
    'tasks': tasks,
  });
  printJudgeSummary(judgeDir, counts, skipped, tasks.length);
}

/// Pools kept findings per case from `<runDir>/results/<model>/<case>-<arm>-
/// r<n>.json`. Files are read in sorted order so the shuffle is reproducible.
Map<String, List<Pooled>> poolFindings(
    String runDir, Eval eval, List<String> skipped, List<String> errors) {
  var root = '$runDir/results';
  var name = RegExp(r'^([^/]+)/(.+)-(arm[12])-r(\d+)\.json$');
  var caseIds = {for (var c in eval.cases) c.id};
  var pooled = <String, List<Pooled>>{};
  for (var rel in listFiles(root).where((f) => f.endsWith('.json'))) {
    var match = name.firstMatch(rel);
    if (match == null || !caseIds.contains(match[2])) {
      errors.add('$rel: unrecognized result file name or case');
      continue;
    }
    Object? data;
    try {
      data = jsonDecode(File('$root/$rel').readAsStringSync());
    } on FormatException catch (e) {
      errors.add('$rel: invalid JSON (${e.message})');
      continue;
    }
    if (data is Map && data.containsKey('inputError')) {
      skipped.add('$rel: ${data['inputError']}');
      continue;
    }
    if (data is! Map || data['comments'] is! List) {
      errors.add('$rel: missing "comments" list');
      continue;
    }
    for (var comment in (data['comments'] as List).whereType<Map>()) {
      var severity = comment['severity'] as String? ?? '';
      if (severityRank(severity) < severityRank('medium')) continue;
      (pooled[match[2]!] ??= []).add((
        comment: comment.cast<String, Object?>(),
        arm: match[3]!,
        model: match[1]!,
        run: int.parse(match[4]!),
      ));
    }
  }
  return pooled;
}

/// Gives [p] the next opaque id (unique across cases), records its source in
/// [mapping], and returns the judge-visible finding.
Map<String, Object?> assignId(
    Pooled p, String caseId, Map<String, Object?> mapping) {
  var id = 'f${(mapping.length + 1).toString().padLeft(3, '0')}';
  mapping[id] = {
    'case': caseId,
    'arm': p.arm,
    'model': p.model,
    'run': p.run,
  };
  var c = p.comment;
  return {
    'id': id,
    'path': c['path'],
    'line': c['line'],
    'severity': c['severity'],
    'title': c['title'],
    'body': c['body'],
  };
}

Map<String, Object?> judgeTask(
    String template, String runDir, EvalCase c, Eval eval) {
  var judgeDir = '$runDir/judge';
  var tree = '$runDir/work/cases/${c.id}/repo';
  var output = '$judgeDir/${c.id}.verdicts.json';
  var policy = eval.policy.isEmpty
      ? '  none'
      : eval.policy.map((p) => '  - $p').join('\n');
  return {
    'id': '${c.id}-judge',
    'case': c.id,
    'model': 'judge',
    'tier': 'inherit',
    'output': output,
    'prompt': fill(template, {
      'FINDINGS': '$judgeDir/${c.id}.findings.json',
      'DIFF': '$runDir/work/cases/${c.id}/diff.patch',
      'REPO': Directory(tree).existsSync() ? '`$tree`' : noRepo,
      'POLICY': policy,
      'OUTPUT': output,
    }),
  };
}

void printJudgeSummary(String judgeDir, Map<String, int> counts,
    List<String> skipped, int taskCount) {
  stdout
    ..writeln('## review-tuner judge inputs\n')
    ..writeln('| Case | Findings |')
    ..writeln('|---|---|');
  for (var MapEntry(:key, :value) in counts.entries) {
    stdout.writeln('| $key | $value${value == 0 ? ' (no judge task)' : ''} |');
  }
  if (skipped.isNotEmpty) {
    stdout.writeln('\nSkipped result files with inputError:');
    for (var s in skipped) {
      stdout.writeln('- $s');
    }
  }
  stdout.writeln('''

- Judge tasks: $taskCount
- Manifest: `$judgeDir/tasks.json`

**Next:** for each task in `$judgeDir/tasks.json`, send its one-line `message` to a fresh, independent judge on its `tier`, in batches of at most 10, then run `score.dart`.''');
}
