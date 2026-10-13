# review-tuner file formats

All paths below are under the per-repo data dir `<dataDir>/<owner>/<repo>/`
(see the user config). Run scripts as `dart <skill_dir>/scripts/<name>.dart`.
All scripts print markdown to stdout. `collect.dart` and `score.dart` also
write JSON to `--output-file` (for `collect`, the corpus JSONL path);
`prepare.dart` has no `--output-file`: it writes `tasks.json` and prompt
files into the run directory. Exit codes: `0` success, `1` a step or query
failed or input data is invalid, `2` bad arguments. A failed query is never
reported as "no results".

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
      prompts/<task id>.md            one reviewer prompt per task
      work/arms/arm1|arm2/...         blinded guidance files
      work/cases/<case>/diff.patch    PR diff at the reviewed commit
      work/cases/<case>/repo/         evaluate only: checkout, agent files removed
      results/<model>/<case>-<arm1|arm2>-r<n>.json
      judge/tasks.json                evaluate only (prepare judge)
      judge/prompts/<task id>.md      one judge prompt per case
      judge/<case>.findings.json
      judge/<case>.verdicts.json
      score.json, report.md
```

## Corpus (written by `collect.dart`)

One PR per line: its metadata (`number`, `title`, `url`, `mergedAt`,
`files`, ...), `author` with `authorRole`/`authorWeight`, `excludedReason`
(automation PRs, skipped by every summary), `truncated`, and `comments`. Each
comment has `kind` (`inline`, `review`, `issue`), `author`, `role`, `weight`,
`isPrAuthor`, `body`, and, when known, `path`, `line`, `commitId`, `threadId`
(the thread's first comment), `threadResolved`, and `severity`. Roles come
from the user config (repo `roles`, then `people`, then GitHub's
`authorAssociation`, else `external`); bots are `bot`. `severity` is set
only on bot comments whose body carries a recognized severity badge (Gemini
Code Assist's `*-priority.svg` / `critical.svg` images); other bots get none.
Readers ignore fields older corpora still have (`reactions`, `commits`,
`postReviewCommits`) and derive `severity` from the body when it's absent.

A corpus line (`PullRequest` / `Comment` in `scripts/src/corpus.dart`;
`?` marks fields written only when known):

```json
{"number": 612, "title": "…", "url": "https://github.com/o/n/pull/612",
 "state": "MERGED", "isDraft": false, "createdAt": "…", "closedAt": "…",
 "mergedAt": "…|null", "baseRefName": "main", "baseRefOid": "…",
 "headRefOid": "…", "labels": ["…"],
 "files": [{"path": "…", "additions": 1, "deletions": 0,
            "changeType": "MODIFIED"}],
 "author": "pq", "authorRole": "maintainer", "authorWeight": 1.0,
 "authorAssociation?": "MEMBER", "outcome": "merged|closed-unmerged",
 "excludedReason?": "automation-author", "threadsTruncated": false,
 "truncated?": ["files|reviewThreads|reviews|issueComments|threadComments"],
 "comments": [{"kind": "inline|review|issue", "id": 123, "author": "…",
               "role": "maintainer", "weight": 1.0,
               "authorAssociation?": "MEMBER", "isPrAuthor": false,
               "body": "…", "createdAt": "…", "path?": "…", "line?": 12,
               "commitId?": "…", "inReplyTo?": 120, "threadId?": 120,
               "reviewId?": 99, "reviewState?": "APPROVED",
               "threadResolved?": true, "threadOutdated?": false,
               "severity?": "high"}]}
```

## Stats (`<corpus base>.stats.json`, written by `collect.dart`)

Counts are over non-automation PRs (`prsConsidered`); reviewer counts
exclude PR authors' own comments.

```json
{"repo": "o/n", "window": {"since": "…", "until": "…"}, "collectedAt": "…",
 "prsTotal": 128, "prsCollected": 128, "prsFailed": 0,
 "prsExcludedAutomation": 18, "prsConsidered": 110, "merged": 101,
 "closedUnmerged": 9, "prsByAuthorRole": {"maintainer": 60},
 "prsWithHumanInlineComments": 27, "prsWithSubstantiveHumanComments": 53,
 "substantiveReviewerCommentsByRole": {"maintainer": 120},
 "reviewers": {"pq": {"role": "maintainer", "weight": 1.0,
                      "substantiveComments": 40, "prs": 12}},
 "bot": {"login": "gemini-code-assist[bot]", "prsWithBotActivity": 80,
         "botInlineComments": 300, "botInlineResolved": 120,
         "humanRepliesToBotInline": 45},
 "truncatedPrs": {"611": ["files"]},
 "unconfiguredFrequentParticipants": [{"login": "…", "authored": 4,
                                       "comments": 21}],
 "failedPrs": {"700": "<error>"},
 "humanCommentsTotal": 339, "humanCommentsWeighted": 285.25}
```

The proposals template's corpus line uses `prsConsidered`,
`humanCommentsTotal`, and `bot.botInlineComments`.

## Digest and `--select` (written by `collect.dart`)

`collect` writes the corpus, `.stats.json`, and the digest
(`<corpus base>.digest.md` / `.digest.json`) together, so a corpus never sits
next to a stale digest. `collect.dart digest --corpus <file>` rewrites the
same two files and prints a short summary plus their paths (`--stdout` prints
the full markdown instead; `--output-file <x.json>` writes `<x>.json` and
`<x>.md` instead of the defaults). `--max-chars N` (default 300) sets the
excerpt length; human replies in bot threads keep up to 3×N, since they carry
the verdict.

The digest lists, per PR, non-trivial human comments outside bot threads and
every human reply in a bot thread. The digest JSON and the stats JSON both
carry `humanCommentsTotal` and `humanCommentsWeighted` (sum of role weights)
over those comments, **excluding the PR author's own**, which are listed
(marked "PR author") but only tallied as `prAuthorComments`. The digest JSON
also has `maxChars`, `humanCommentsByRole` (also excluding PR authors),
`botThreads`, `botThreadsResolved`, `botThreadsWithHumanReply`, `topPaths`,
and `prs`.

`collect.dart digest --corpus <file> --select <regex> [--path <regex>] [--bot]
[--output-file <x.json>]` counts comments in non-automation PRs whose full
body matches (case-insensitive); `--path` filters by comment path (comments
without a path never match it). Default: substantive human comments (not
trivial like "LGTM"; human replies in bot threads always count); `--bot`: the
configured reviewer bot's comments only. `n`, `weighted`, `prs`, and
`reviewers` leave out comments by the PR's own author: those are still
listed in `matches` (with `isPrAuthor`) and counted as `prAuthorComments`.
It never writes the digest files. A run with no matches exits 0 with
`n: 0`; an invalid regex exits 2.

```json
{"repo": "o/n", "corpus": "<path>", "select": "copyright", "path": "…",
 "comments": "human|bot", "n": 2, "weighted": 2.0, "prAuthorComments": 0,
 "prs": [596, 663],
 "reviewers": [{"login": "pq", "role": "maintainer"}],
 "withHumanReply": 0, "resolved": 0,
 "matches": [{"pr": 596, "author": "pq", "role": "maintainer", "weight": 1.0,
              "isPrAuthor": true, "kind": "inline", "path": "…", "line": 1,
              "commitId": "6e97ae9…",
              "humanReply": false, "resolved": true,
              "text": "160-char excerpt", "url": "…#discussion_r123"}]}
```

`withHumanReply`, `resolved`, and the per-match `humanReply`/`resolved` appear
only with `--bot`; `isPrAuthor`, `path`, `line`, `commitId`, and `url` only
when known. `commitId` (also on digest comments and bot threads; the markdown
shows its first 10 characters as `@<sha>`) is the commit an inline comment
was made on: use it as a case's `commit`. A
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
| `type` | `add`, `edit` (default), `remove`, or `fix` |
| `affects` | which reviewer reads the changed file: `bot` (default; e.g. GCA), `local`, or `both` |
| `models` | first entry is the primary; results are reported per model, never pooled. Default: one run on the agent's own model (`inherit`). `check` always uses only the first model with one run; `evaluate` uses every model and its `runs` |
| `concern` | the single flag rule (below); `cite`/`objection` are case-insensitive regexes (not the starter `TODO` text), `minSeverity` one of `low`, `medium`, `high`, `critical`; `tags` are matched case-insensitively (both sides lower-cased) |
| `pathGroups` | named groups of path substrings; `any` always matches |
| `cases` | at least one case; each is either a real PR (`pr` + the reviewed `commit`) or synthetic (`patch`, plus an optional `commit` to apply it to), never both |
| `cases[].set` | `motivating`, `heldout`, `guard`, `negative`, or `info` |
| `cases[].want` | `flag`, `no-flag`, or `none` (default; informational, not scored) |
| `cases[].group` | `any` (default) or a key of `pathGroups`: the path group the concern is checked in |
| `evidence` | inputs to the rubric's Evidence row: `weightedComments`, `prs`, `reviewers`, `maintainer`, `contradiction`. Required for `evaluate` (scoring without it exits `1`) |
| `policy` | optional list of owner-maintained facts given to the judge as ground truth (evaluate only) |
| `corpus` | optional corpus path, relative to the eval dir: enables bot fidelity against the repo's configured `bot` |

**Flag rule.** A comment flags the concern when it is in the case's path group,
is not `low`, and either is at least `minSeverity` and matches `cite` or
`objection`, or matches `cite` and carries one of `tags`.

**Kept findings.** Scoring and the judge use only *kept* reviewer comments: a
known severity of `medium` or higher (`isKept` in `scripts/src/eval.dart`).

Content errors in `eval.json` (a `set`, `want`, `type`, or `affects` value
not spelled exactly as above, an unknown group, a bad case source, a `TODO`
or invalid regex, a bad `minSeverity`, no cases) exit `1` with a message
naming the field and the allowed values; `2` is only for bad command-line
arguments, including unknown options.

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
     "message": "Read <promptFile> and follow its instructions exactly."}
  ]
}
```

The orchestrator sends each task's one-line `message` to an independent
worker (a subagent on the given `tier` where supported) and does nothing else:
**the worker writes its own result file to `output`.** Workers never see
`tasks.json`, so the `arms` mapping stays hidden from them. Arm assignment is
randomized per `prepare` run (`seed` records it). `prepare` refuses to
overwrite a run directory that already has results. `score.dart` reads the
eval from `evalDir` and uses `mode` (an `evaluate` run requires noise data).
The PR diff is `merge-base(PR base, commit)...commit`, using the PR's own
base commit (`pulls/<n>` → `base.sha`), not the current default branch.
`evaluate` checkouts have every [agent file](#agent-files) and harness
guidance path removed.

## Agent files

The files review-tuner treats as agent guidance, both when auditing a repo
(propose mode) and when stripping `evaluate` checkouts (`src/agent_files.dart`):

- `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `SKILL.md`, `.aiconfig`, and
  `.aiexclude`, at any depth;
- everything under `.gemini/`, `.agents/`, `.claude/`, and `.cursor/`, at any
  depth;
- `.github/copilot-instructions.md`.

## Result file (written by a reviewer)

```json
{"summary": "2-4 sentences",
 "comments": [{"path": "repo/relative/path", "line": 12,
               "severity": "critical|high|medium|low",
               "title": "short", "body": "text"}]}
```

or, if an input could not be read: `{"inputError": "<reason>"}`.

## Judge files (evaluate only)

`prepare.dart judge` reads the `output` of every task of the **primary**
model (the first in `eval.json` `models`; noise is scored on it only) from
`tasks.json` (a missing or unparsable result is an error; an `inputError`
result is skipped), pools every kept finding (severity ≥ medium) per case
from both arms and all runs, shuffles them with a fixed seed, and writes
`judge/<case>.findings.json` for every case (`[{"id": "f001", "path", "line",
"severity", "title", "body"}]`; ids are unique across cases; an empty list
means "judged, nothing to judge") plus `judge/tasks.json` (same shape as above,
plus a `mapping` from finding id to `{case, arm, model, run}`). Each judge
writes `judge/<case>.verdicts.json`:

```json
{"verdicts": [{"id": "f001", "verdict": "valid|noise|wrong", "reason": "…"}]}
```

`score.dart fidelity` reads the eval's `corpus` and compares against the
bot's inline comments at each motivating case's `commit`, using their
normalized `severity`. If none of those comments has a severity or carries
one of the concern's `tags`, fidelity is reported as not measurable for that
bot (no rubric modifier) rather than 0%.

Once `judge/tasks.json` exists, `score.dart validate` (and every other
`score` subcommand, which validate first) checks each judge output: it
parses, has a `verdicts` list, judges every finding id of its case exactly
once, and uses only `valid`, `noise`, or `wrong`.

## `score.json` (written by `score.dart all`)

`score.dart all` writes `<run>/score.json` only when nothing is missing or
invalid; `--output-file` gets the same JSON (a single subcommand writes just
its own section). Reports and templates take their numbers from it.

```json
{"validate": {"ok": true, "tasks": 100, "missing": [], "unparsable": [],
              "invalid": {}, "inputError": {}, "warnings": [],
              "judge": {}},
 "replay": {"<model>": {
   "cases": {"<case>": {"baseline": {"runs": 3, "flagged": 2},
                        "candidate": {"runs": 3, "flagged": 0}}},
   "sets": {"<set>/<want>": {"cases": 3,
                             "baseline": {"flagged": 6, "correct": 3, "runs": 9},
                             "candidate": {"flagged": 1, "correct": 8, "runs": 9}}},
   "delta": {"<set>": 0.56},
   "consistency": {"baseline": 1, "candidate": 3, "cases": 3},
   "verdict": {"verdict": "helps|no effect|hurts", "baselineCorrect": 14,
               "baselineRuns": 27, "candidateCorrect": 26,
               "candidateRuns": 27, "rateDelta": 0.44,
               "lostFlagCases": []}}},
 "noise": {"<primary>": {
   "sets": {"<set>": {"baseline": {"all": 1.33, "nonTarget": 1.33},
                      "candidate": {"all": 0.83, "nonTarget": 0.83},
                      "cases": 2}},
   "baselineConcernFlags": {"flags": 19, "wrong": 19}}},
 "fidelity": {"bot": "…", "locations": [{"case": "pr612", "path": "…"}],
              "recallOnly": true,
              "models": {"<model>": {"reproduced": 10, "locationRuns": 21,
                                     "rate": 0.48, "perRun": {"1": 0},
                                     "perLocation": {"<case> <path>": 2}}}},
 "rubric": {"rows": [{"row": "Evidence|Replay|Noise|Fidelity|Robustness",
                      "result": "…", "level": "High|…|no modifier"}],
            "overall": "High|Medium|Low|Reject"}}
```

`noise` is present once the judge has run; `fidelity` when `eval.json` sets
`corpus` (`{"bot", "measurable": false}` when the bot's comments carry no
usable severity or tag; no `models` when the bot flagged nothing).
