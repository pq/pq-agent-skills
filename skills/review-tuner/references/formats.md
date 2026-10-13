# review-tuner file formats

All paths below are under the per-repo data dir `<dataDir>/<owner>/<repo>/`
(see the user config). Scripts print markdown to stdout and write JSON with
`--output-file`. Exit codes: `0` success, `1` a step or query failed, `2` bad
arguments. A failed query is never reported as "no results".

```
<dataDir>/<owner>/<repo>/
  repo/                               clone of the target repo (collect/prepare)
  corpus/<since>_<until>.jsonl        collect.dart output (one PR per line)
  corpus/<since>_<until>.stats.json   review-density summary
  corpus/<since>_<until>.digest.md    digest (written by collect and digest)
  corpus/<since>_<until>.digest.json  the same digest as JSON
  proposals/<date>/report.md          propose mode output
  evals/<id>/
    eval.json                         the evaluation definition (below)
    arms/baseline/<repo-relative files>
    arms/candidate/<repo-relative files>
    patches/<case>.patch              synthetic cases
    check/ | evaluate/                one directory per mode (prepare --out)
      tasks.json                      reviewer task manifest (below)
      work/arms/arm1|arm2/...         blinded guidance files
      work/cases/<case>/diff.patch    PR diff at the reviewed commit
      work/cases/<case>/repo/         evaluate only: checkout, agent files removed
      results/<model>/<case>-<arm1|arm2>-r<n>.json
      judge/tasks.json                evaluate only (prepare judge)
      judge/<case>.findings.json
      judge/<case>.verdicts.json
      score.json, report.md
```

## Digest and `--select` (written by `collect.dart`)

`collect` writes the corpus, `.stats.json`, and the digest
(`<corpus base>.digest.md` / `.digest.json`) together, so a corpus never sits
next to a stale digest. `collect.dart digest --corpus <file>` rewrites the
same two files and prints a short summary plus their paths (`--stdout` prints
the full markdown instead; `--output-file <x.json>` writes `<x>.json` and
`<x>.md` instead of the defaults). `--max-chars N` (default 300) sets the
excerpt length; human replies in bot threads keep up to 3×N, since they carry
the verdict.

The digest JSON and the stats JSON both carry `humanCommentsTotal` and
`humanCommentsWeighted` (sum of role weights): the digest's human comments,
i.e. non-trivial human comments outside bot threads plus every human reply in
a bot thread. The digest JSON also has `maxChars`, `humanCommentsByRole`,
`botThreads`, `botThreadsResolved`, `botThreadsWithHumanReply`, `topPaths`,
and `prs`.

`collect.dart digest --corpus <file> --select <regex> [--path <regex>] [--bot]
[--output-file <x.json>]` counts comments in non-automation PRs whose full
body matches (case-insensitive); `--path` filters by comment path (comments
without a path never match it). Default: human comments; `--bot`: the
configured reviewer bot's comments only. It never writes the digest files.
A run with no matches exits 0 with `n: 0`; an invalid regex exits 2.

```json
{"repo": "o/n", "corpus": "<path>", "select": "copyright", "path": "…",
 "comments": "human|bot", "n": 2, "weighted": 2.0, "prs": [596, 663],
 "reviewers": [{"login": "pq", "role": "maintainer"}],
 "withHumanReply": 0, "resolved": 0,
 "matches": [{"pr": 596, "author": "pq", "role": "maintainer", "weight": 1.0,
              "isPrAuthor": true, "kind": "inline", "path": "…", "line": 1,
              "humanReply": false, "resolved": true,
              "text": "160-char excerpt", "url": "…#discussion_r123"}]}
```

`withHumanReply`, `resolved`, and the per-match `humanReply`/`resolved` appear
only with `--bot`; `isPrAuthor`, `path`, `line`, and `url` only when known. A
bot comment has a human reply when a non-bot comment follows it in the same
review thread.

## `eval.json`

```json
{
  "id": "p0-1-third-party",
  "repo": "flutter/dart-intellij-third-party",
  "type": "fix",
  "affects": "bot",
  "models": [{"tier": "pro", "runs": 3, "label": "pro"},
             {"tier": "flash", "runs": 1}],
  "concern": {
    "cite": "third[- ]party|thirdPartySrc|copied from upstream",
    "objection": "generated|manual(ly)? (edit|modif)|direct(ly)? modif",
    "minSeverity": "high",
    "tags": ["[MUST-FIX]"]
  },
  "pathGroups": {
    "protected": ["third_party/thirdPartySrc/platform-lsp/"],
    "allowed": ["third_party/thirdPartySrc/analysisServer/com/google/dart/server/"]
  },
  "cases": [
    {"id": "pr612", "pr": 612, "commit": "6e97ae9…", "set": "motivating",
     "group": "allowed", "want": "no-flag"},
    {"id": "synth-guard", "patch": "patches/synth-guard.patch", "set": "guard",
     "group": "protected", "want": "flag"},
    {"id": "pr696", "pr": 696, "commit": "87ccbd8…", "set": "negative",
     "want": "no-flag"}
  ],
  "evidence": {"weightedComments": 7, "prs": 3, "reviewers": ["some-maintainer"],
               "maintainer": true, "contradiction": true},
  "corpus": "../../corpus/2026-07-07_2026-10-05.jsonl"
}
```

| Field | Meaning |
|---|---|
| `type` | `add`, `edit`, `remove`, or `fix` |
| `affects` | which reviewer reads the changed file: `bot` (e.g. GCA), `local`, or `both` |
| `models` | first entry is the primary; results are reported per model, never pooled. Default: one run on the agent's own model (`inherit`) |
| `concern` | the single flag rule (below) |
| `pathGroups` | named groups of path substrings; `any` always matches |
| `cases[].set` | `motivating`, `heldout`, `guard`, `negative`, or `info` |
| `cases[].want` | `flag`, `no-flag`, or `none` (informational, not scored) |
| `cases[].group` | path group the concern is checked in; default `any` |
| `evidence` | inputs to the rubric's Evidence row |
| `policy` | optional list of owner-maintained facts given to the judge as ground truth (evaluate only) |
| `corpus` | optional, enables bot fidelity |

**Flag rule.** A comment flags the concern when it is in the case's path group,
is not `low`, and either is at least `minSeverity` and matches `cite` or
`objection`, or matches `cite` and carries one of `tags`.

## `tasks.json` (written by `prepare.dart`)

```json
{
  "eval": "p0-1-third-party",
  "evalDir": "<abs>",
  "mode": "check",
  "seed": 1791897195325773,
  "arms": {"arm1": "candidate", "arm2": "baseline"},
  "tasks": [
    {"id": "pr612-arm1-pro-r1", "case": "pr612", "arm": "arm1",
     "model": "pro", "tier": "pro", "run": 1,
     "output": "<abs>/results/pro/pr612-arm1-r1.json",
     "promptFile": "<abs>/prompts/pr612-arm1-pro-r1.md",
     "message": "Read <promptFile> and follow its instructions exactly.",
     "prompt": "<the same text as promptFile>"}
  ]
}
```

The orchestrator sends each task's one-line `message` to an independent
worker (a subagent on the given `tier` where supported) and does nothing else:
**the worker writes its own result file to `output`.** Workers never see
`tasks.json`, so the `arms` mapping stays hidden from them. Arm assignment is
randomized per `prepare` run (`seed` records it). `prepare` refuses to
overwrite a run directory that already has results.

## Result file (written by a reviewer)

```json
{"summary": "2-4 sentences",
 "comments": [{"path": "repo/relative/path", "line": 12,
               "severity": "critical|high|medium|low",
               "title": "short", "body": "text"}]}
```

or, if an input could not be read: `{"inputError": "<reason>"}`.

## Judge files (evaluate only)

`prepare.dart judge` pools every kept finding (severity ≥ medium) per case from
all arms, runs, and models, shuffles them with a fixed seed, and writes
`judge/<case>.findings.json` for every case (`[{"id": "f001", "path", "line",
"severity", "title", "body"}]`; ids are unique across cases; an empty list
means "judged, nothing to judge") plus `judge/tasks.json` (same shape as above,
plus a `mapping` from finding id to `{case, arm, model, run}`). Each judge
writes `judge/<case>.verdicts.json`:

```json
{"verdicts": [{"id": "f001", "verdict": "valid|noise|wrong", "reason": "…"}]}
```
