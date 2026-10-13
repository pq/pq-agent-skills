/// Prepares review-tuner evaluations: scaffolds an eval (`init`), builds
/// blinded reviewer task manifests (`check` diff-only, `evaluate` with
/// checkouts), and builds blind judge tasks (`judge`). It never runs a
/// reviewer or judge: the orchestrator sends each task's `message` to a fresh
/// agent.
///
/// Usage (also printed by `--help` and on a usage error):
///
///     dart prepare.dart init --repo <owner/name|alias> --id <id> [--config <path>]
///     dart prepare.dart check --eval <evalDir> [--runs <n>] [--out <dir>] [--seed <n>] [--config <path>]
///     dart prepare.dart evaluate --eval <evalDir> [--out <dir>] [--seed <n>] [--config <path>]
///     dart prepare.dart judge --run <runDir> [--seed <n>]
///
/// The data layout, every file format, and exit codes:
/// `references/formats.md`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'src/agent_files.dart';
import 'src/cli.dart';
import 'src/config.dart';
import 'src/eval.dart';

const usage = '''
Usage:
  dart prepare.dart init --repo <owner/name|alias> --id <id> [--config <path>]
  dart prepare.dart check --eval <evalDir> [--runs <n>] [--out <dir>] [--seed <n>] [--config <path>]
  dart prepare.dart evaluate --eval <evalDir> [--out <dir>] [--seed <n>] [--config <path>]
  dart prepare.dart judge --run <runDir> [--seed <n>]''';

/// REPO value given to reviewers in check mode.
const noRepo = 'none (diff-only review)';

/// The neutral arm names reviewers see.
const blindArms = ['arm1', 'arm2'];

/// Seed for the judge's finding shuffle when `--seed` is not given.
const defaultJudgeSeed = 42;

/// Where the orchestrator learns how to send tasks (batching, tiers,
/// reruns).
const dispatchDocs = 'SKILL.md, "Dispatching tasks"';

/// The skill directory (this script lives in `<skill>/scripts/`).
final skillDir = File(Platform.script.toFilePath()).parent.parent.path;

/// Options each subcommand accepts.
const commandOptions = {
  'init': {'repo', 'id', 'config'},
  'check': {'eval', 'runs', 'out', 'seed', 'config'},
  'evaluate': {'eval', 'out', 'seed', 'config'},
  'judge': {'run', 'seed'},
};

Future<void> main(List<String> argv) => guarded(usage, argv, () async {
      var command = argv.firstOrNull;
      var allowed = commandOptions[command] ??
          usageError('Unknown or missing command "${command ?? ''}".');
      var args = parseArgs(argv.sublist(1), options: allowed);
      if (args.positional.isNotEmpty) usageError('Unexpected arguments.');
      var options = args.options;
      switch (command) {
        case 'init':
          await init(options);
        case 'check':
          await prepare(options, thorough: false);
        case 'evaluate':
          await prepare(options, thorough: true);
        case 'judge':
          judge(options);
      }
    });

// ---------------------------------------------------------------- helpers

String need(Map<String, String> options, String name) =>
    options[name] ?? usageError('Missing --$name');

int? intOption(Map<String, String> options, String name) {
  var value = options[name];
  if (value == null) return null;
  return int.tryParse(value) ?? usageError('--$name must be an integer');
}

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
  var slug = need(options, 'repo');
  var repo = config.repo(slug) ??
      usageError('Unknown repo "$slug": use owner/name or an alias.');
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
    } on CommandException catch (e) {
      if (!e.notFound) fail('$e');
    }
  }
  // Every fetch succeeded: create both arms (even if empty) or neither.
  for (var arm in ['baseline', 'candidate']) {
    Directory('$evalDir/arms/$arm').createSync(recursive: true);
    for (var MapEntry(:key, :value) in files.entries) {
      writeText('$evalDir/arms/$arm/$key', value);
    }
  }
  writeJson('$evalDir/eval.json', starterEval(repo, id));
  printInitSummary(evalDir, repo, files.keys.toList());
}

Map<String, Object?> starterEval(RepoConfig repo, String id) => {
      'id': id,
      'repo': repo.slug,
      'type': 'edit',
      'affects': 'bot',
      'models': [Eval.defaultModel],
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
3. Run `dart $skillDir/scripts/prepare.dart check --eval $evalDir`.''');
}

// --------------------------------------------------------- check/evaluate

Future<void> prepare(Map<String, String> options,
    {required bool thorough}) async {
  var evalDir = absPath(need(options, 'eval'));
  var eval = loadEval(evalDir);
  if (eval.cases.isEmpty) fail('$evalDir/eval.json has no cases.');
  var config = loadConfig(path: options['config']);
  var repo = config.repo(eval.repo) ??
      fail('$evalDir/eval.json: repo "${eval.repo}" is not owner/name or an '
          'alias.');
  var mode = thorough ? 'evaluate' : 'check';
  var runs = intOption(options, 'runs') ?? 1;
  if (runs < 1) usageError('--runs must be at least 1');
  var out = absPath(options['out'] ?? '$evalDir/$mode');
  var seed =
      intOption(options, 'seed') ?? DateTime.now().microsecondsSinceEpoch;
  refuseExisting('$out/results', '.json', 'result files');
  File('$out/tasks.json').parent.createSync(recursive: true);
  deletePath('$out/tasks.json');

  var assignment = writeArms(
      evalDir: evalDir, out: out, eval: eval, repo: repo, rng: Random(seed));
  var checkout = thorough ? await openClone(config, repo) : null;
  var (:repoText, :failures) = await prepareCases(
      eval: eval, evalDir: evalDir, out: out, repo: repo, checkout: checkout);
  printCases(eval: eval, out: out, repoText: repoText, failures: failures);
  if (failures.isNotEmpty) {
    fail('\n${failures.length} case(s) failed; tasks.json was not written.');
  }
  // check: --runs runs (default 1) on the primary model; evaluate: every
  // model and run.
  var models = thorough
      ? eval.models
      : [(tier: eval.primary.tier, runs: runs, label: eval.primary.label)];
  var tasks =
      buildTasks(eval: eval, models: models, out: out, repoText: repoText);
  writePromptFiles('$out/prompts', tasks);
  writeJson('$out/tasks.json', {
    'eval': eval.id,
    'evalDir': evalDir,
    'mode': mode,
    'seed': seed,
    'arms': assignment,
    'tasks': tasks,
  });
  printNextSteps(eval: eval, out: out, tasks: tasks, seed: seed);
}

/// The target repo's clone and the default branch fetched into it.
typedef Checkout = ({String clone, String branch});

/// Writes each case's diff (and, with a [checkout], its worktree). Returns
/// the REPO text reviewers get per case id, and failures by case id.
Future<({Map<String, String> repoText, Map<String, String> failures})>
    prepareCases({
  required Eval eval,
  required String evalDir,
  required String out,
  required RepoConfig repo,
  required Checkout? checkout,
}) async {
  var repoText = <String, String>{};
  var failures = <String, String>{};
  for (var c in eval.cases) {
    var caseDir = '$out/work/cases/${c.id}';
    try {
      var base = await writeDiff(c, evalDir, caseDir, repo);
      if (checkout == null) {
        repoText[c.id] = noRepo;
        continue;
      }
      var tree = await makeWorktree(
          c: c, caseDir: caseDir, base: base, checkout: checkout, repo: repo);
      repoText[c.id] = '`$tree`';
    } on CommandException catch (e) {
      failures[c.id] = '$e';
    } on FileSystemException catch (e) {
      failures[c.id] = '$e';
    }
  }
  return (repoText: repoText, failures: failures);
}

/// Moves each task's `prompt` to `<dir>/<id>.md` and adds `promptFile` plus
/// a one-line `message` the orchestrator can send verbatim, so reviewers
/// never need to see `tasks.json` (which holds the arm mapping).
void writePromptFiles(String dir, List<Map<String, Object?>> tasks) {
  for (var t in tasks) {
    var path = '$dir/${t['id']}.md';
    writeText(path, t.remove('prompt') as String);
    t['promptFile'] = path;
    t['message'] = 'Read $path and follow its instructions exactly.';
  }
}

/// Materializes the blinded arms under `<out>/work/arms/` and returns the
/// neutral-name assignment (e.g. `{arm1: candidate, arm2: baseline}`).
Map<String, String> writeArms({
  required String evalDir,
  required String out,
  required Eval eval,
  required RepoConfig repo,
  required Random rng,
}) {
  var baseline = '$evalDir/arms/baseline';
  var present = listFiles(baseline);
  var missing = repo.harness.guidance.where((p) => !present.contains(p));
  if (eval.type != ChangeType.add && missing.isNotEmpty) {
    fail('Missing baseline guidance in $baseline: ${missing.join(', ')}\n'
        '(set "type": "add" if the candidate adds a new file).');
  }
  var candidateFirst = rng.nextBool();
  var [first, second] = blindArms;
  var assignment = {
    first: candidateFirst ? 'candidate' : 'baseline',
    second: candidateFirst ? 'baseline' : 'candidate',
  };
  deletePath('$out/work/arms');
  for (var MapEntry(:key, :value) in assignment.entries) {
    var dir = '$out/work/arms/$key';
    Directory(dir).createSync(recursive: true);
    copyTree(baseline, dir);
    if (value == 'candidate') copyTree('$evalDir/arms/candidate', dir);
  }
  if (sameTree('$out/work/arms/$first', '$out/work/arms/$second')) {
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
/// the reviewed commit (`merge-base(PR base, commit)...commit`), fetched
/// without a clone; returns the merge base. Synthetic cases copy the patch.
Future<String?> writeDiff(
    EvalCase c, String evalDir, String caseDir, RepoConfig repo) async {
  var target = '$caseDir/diff.patch';
  Directory(caseDir).createSync(recursive: true);
  if (c.patch case var patch?) {
    File('$evalDir/$patch').copySync(target);
    return null;
  }
  // The PR's own base, not the current default branch: in repos that merge
  // with merge commits the reviewed commit is already on the default branch.
  var prBase = (await gh(
          ['api', 'repos/${repo.slug}/pulls/${c.pr}', '--jq', '.base.sha'],
          step: 'PR base'))
      .trim();
  var base = (await gh([
    'api',
    'repos/${repo.slug}/compare/$prBase...${c.commit}',
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
  if (diff.trim().isEmpty) throw CommandException('fetch diff', 'empty diff');
  File(target).writeAsStringSync(diff);
  return base;
}

/// Returns the clone at `<repoDir>/repo`, cloning it if missing, with the
/// default branch fetched.
Future<Checkout> openClone(Config config, RepoConfig repo) async {
  var branch = await defaultBranch(repo);
  var clone = '${config.repoDir(repo)}/repo';
  if (!Directory(clone).existsSync()) {
    Directory(clone).parent.createSync(recursive: true);
    await gh(['repo', 'clone', repo.slug, clone, '--', '--quiet'],
        step: 'clone');
  }
  await git(clone, ['fetch', '--quiet', 'origin', branch],
      step: 'fetch $branch');
  return (clone: clone, branch: branch);
}

/// The reviewed commit may predate a force-push, so fetch it by SHA if the
/// PR head fetch did not bring it in.
Future<void> ensureCommit(String clone, String sha) async {
  try {
    await git(clone, ['cat-file', '-e', '$sha^{commit}']);
  } on CommandException {
    await git(clone, ['fetch', '--quiet', 'origin', sha],
        step: 'fetch commit $sha');
  }
}

/// Creates `<caseDir>/repo`: a detached worktree whose HEAD is the merge base
/// ([base], null for a synthetic case) and whose working tree has the case's
/// changes uncommitted, with every agent file ([agentRoot], at any depth)
/// and harness guidance path removed. Returns its path.
Future<String> makeWorktree({
  required EvalCase c,
  required String caseDir,
  required String? base,
  required Checkout checkout,
  required RepoConfig repo,
}) async {
  var (:clone, :branch) = checkout;
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
  if (base case var mergeBase?) {
    // Working tree keeps the reviewed commit; HEAD and index move to the
    // merge base, leaving exactly the PR's changes uncommitted.
    await git(tree, ['reset', '--quiet', mergeBase],
        step: 'reset to merge base');
  } else {
    await git(tree, ['apply', '--whitespace=nowarn', '$caseDir/diff.patch'],
        step: 'apply patch');
  }
  await stripAgentFiles(tree, repo);
  return tree;
}

/// Deletes agent files and directories anywhere in [tree] (tracked or new),
/// plus [repo]'s harness guidance paths.
Future<void> stripAgentFiles(String tree, RepoConfig repo) async {
  var files = await git(
      tree, ['ls-files', '-z', '--cached', '--others', '--exclude-standard'],
      step: 'list files');
  var roots = {
    for (var f in files.split('\x00'))
      if (agentRoot(f) case var root?) root,
    ...repo.harness.guidance,
  };
  for (var path in roots) {
    deletePath('$tree/$path');
  }
}

List<Map<String, Object?>> buildTasks({
  required Eval eval,
  required List<ModelSpec> models,
  required String out,
  required Map<String, String> repoText,
}) {
  var template = readPrompt('reviewer');
  return [
    for (var m in models)
      for (var c in eval.cases)
        for (var arm in blindArms)
          for (var run = 1; run <= m.runs; run++)
            reviewerTask(
              template: template,
              out: out,
              caseId: c.id,
              arm: arm,
              model: m,
              run: run,
              guidance: guidanceBullets(out, arm),
              repo: repoText[c.id] ?? noRepo,
            ),
  ];
}

Map<String, Object?> reviewerTask({
  required String template,
  required String out,
  required String caseId,
  required String arm,
  required ModelSpec model,
  required int run,
  required String guidance,
  required String repo,
}) {
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

void printCases({
  required Eval eval,
  required String out,
  required Map<String, String> repoText,
  required Map<String, String> failures,
}) {
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

void printNextSteps({
  required Eval eval,
  required String out,
  required List<Map<String, Object?>> tasks,
  required int seed,
}) {
  var perModel = <String, int>{};
  for (var t in tasks) {
    perModel.update(t['model'] as String, (n) => n + 1, ifAbsent: () => 1);
  }
  var counts = perModel.entries.map((e) => '`${e.key}`: ${e.value}');
  stdout.writeln('''

- Cases prepared: ${eval.cases.length}
- Tasks: ${tasks.length} (${counts.join(', ')})
- Manifest: `$out/tasks.json` (arm seed $seed)

**Next:** for each task in `$out/tasks.json`, send its one-line `message` to a fresh, independent reviewer on its `tier` (see $dispatchDocs), then run `dart $skillDir/scripts/score.dart validate --run $out`.''');
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
  var seed = intOption(options, 'seed') ?? defaultJudgeSeed;
  var manifest = readJson('$runDir/tasks.json') as Map<String, Object?>;
  var evalDir = manifest['evalDir'] as String? ?? File(runDir).parent.path;
  var eval = loadEval(evalDir);
  var judgeDir = '$runDir/judge';
  refuseExisting(judgeDir, '.verdicts.json', 'verdict files');

  // Noise is scored on the primary model only, so only its findings are
  // judged.
  var tasks = [
    for (var t in (manifest['tasks'] as List).cast<Map<String, Object?>>())
      if (t['model'] == eval.primary.label) t,
  ];
  var (:pooled, :skipped, :errors) = poolFindings(tasks);
  if (errors.isNotEmpty) {
    fail('Unusable result files (nothing written):\n'
        '${errors.map((e) => '- $e').join('\n')}');
  }
  var (:mapping, :judgeTasks, :counts) =
      writeFindings(eval: eval, runDir: runDir, pooled: pooled, seed: seed);
  writePromptFiles('$judgeDir/prompts', judgeTasks);
  writeJson('$judgeDir/tasks.json', {
    'eval': eval.id,
    'mode': 'judge',
    'seed': seed,
    'arms': manifest['arms'],
    'mapping': mapping,
    'tasks': judgeTasks,
  });
  printJudgeSummary(
    runDir: runDir,
    model: eval.primary.label,
    counts: counts,
    skipped: skipped,
    taskCount: judgeTasks.length,
  );
}

/// Shuffles each case's [pooled] findings with [seed] and writes
/// `judge/<case>.findings.json` for every case (ids unique across cases).
/// Returns the id-to-source mapping, a judge task per case with findings,
/// and the finding count per case.
({
  Map<String, Object?> mapping,
  List<Map<String, Object?>> judgeTasks,
  Map<String, int> counts,
}) writeFindings({
  required Eval eval,
  required String runDir,
  required Map<String, List<Pooled>> pooled,
  required int seed,
}) {
  var template = readPrompt('judge');
  var mapping = <String, Object?>{};
  var judgeTasks = <Map<String, Object?>>[];
  var counts = <String, int>{};
  for (var c in eval.cases) {
    var findings = pooled[c.id] ?? <Pooled>[];
    findings.shuffle(Random(seed));
    var visible = [
      for (var p in findings) assignId(p, c.id, mapping),
    ];
    writeJson('$runDir/judge/${c.id}.findings.json', visible);
    counts[c.id] = visible.length;
    if (visible.isNotEmpty) {
      judgeTasks.add(judgeTask(template, runDir, c, eval));
    }
  }
  return (mapping: mapping, judgeTasks: judgeTasks, counts: counts);
}

/// Pools kept findings per case from every reviewer task's `output`. Tasks
/// are read in `output` order so the shuffle is reproducible. Also returns
/// results skipped for an `inputError` and unusable result files.
({
  Map<String, List<Pooled>> pooled,
  List<String> skipped,
  List<String> errors,
}) poolFindings(List<Map<String, Object?>> tasks) {
  var pooled = <String, List<Pooled>>{};
  var skipped = <String>[], errors = <String>[];
  var ordered = [...tasks]
    ..sort((a, b) => (a['output'] as String).compareTo(b['output'] as String));
  for (var t in ordered) {
    var output = t['output'] as String;
    Object? data;
    try {
      data = jsonDecode(File(output).readAsStringSync());
    } on FileSystemException {
      errors.add('$output: missing');
      continue;
    } on FormatException catch (e) {
      errors.add('$output: invalid JSON (${e.message})');
      continue;
    }
    if (data is Map && data.containsKey('inputError')) {
      skipped.add('$output: ${data['inputError']}');
      continue;
    }
    if (data is! Map || data['comments'] is! List) {
      errors.add('$output: missing "comments" list');
      continue;
    }
    for (var raw in (data['comments'] as List).whereType<Map>()) {
      var comment = raw.cast<String, Object?>();
      if (!isKept(comment)) continue;
      (pooled[t['case'] as String] ??= []).add((
        comment: comment,
        arm: t['arm'] as String,
        model: t['model'] as String,
        run: t['run'] as int,
      ));
    }
  }
  return (pooled: pooled, skipped: skipped, errors: errors);
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

void printJudgeSummary({
  required String runDir,
  required String model,
  required Map<String, int> counts,
  required List<String> skipped,
  required int taskCount,
}) {
  var judgeDir = '$runDir/judge';
  stdout
    ..writeln('## review-tuner judge inputs ($model findings)\n')
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
  var score = 'dart $skillDir/scripts/score.dart';
  stdout.writeln('''

- Findings pooled: ${counts.values.fold(0, (a, n) => a + n)} (primary model `$model` only; noise is scored on it)
- Judge tasks: $taskCount
- Manifest: `$judgeDir/tasks.json`

**Next:** for each task in `$judgeDir/tasks.json`, send its one-line `message` to a fresh, independent judge on its `tier` (see $dispatchDocs), then run `$score validate --run $runDir` and `$score all --run $runDir`.''');
}
