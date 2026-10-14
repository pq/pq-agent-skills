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
  repo/                               clone of the target repo (prepare)
  head/                               depth-1 clone of the default branch (collect guidance)
  corpus/<since>_<until>.jsonl        collect.dart output (one PR per line)
  corpus/<since>_<until>.stats.json   review-density summary
  corpus/<since>_<until>.digest.md    digest (written by collect and digest)
  corpus/<since>_<until>.digest.json  the same digest as JSON
  corpus/<since>_<until>.digest-<view>.md|.json  digest views (digest --view)
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

## User config

Example: [config.example.json](config.example.json). Every key is optional.

| Key | Meaning |
|---|---|
| `dataDir` | root of the data layout above (default `~/review-tuner-data`) |
| `weights` | role → weight (defaults: `maintainer` 1.0, `external` 0.5; unknown roles get the `external` weight) |
| `people` | login → role, in every repo |
| `agentAuthors` | AI agent accounts in every repo (added to each repo's list) |
| `repos.<owner/name>.alias` | short name for `--repo` |
| `repos.….bot` | the review bot's login (default `gemini-code-assist[bot]`) |
| `repos.….harness.guidance` | guidance files a simulated reviewer reads |
| `repos.….roles` | login → role in this repo (overrides `people`) |
| `repos.….automationAuthors` | automation accounts: their PRs are excluded, their comments are `bot` |
| `repos.….automationPatterns` | login regexes (case-insensitive) treated like `automationAuthors`; replaces the defaults, `[]` disables them |
| `repos.….agentAuthors` | AI agent accounts: their PRs are **kept**, their own comments are `agent` |

Default `automationPatterns` (every repo, configured or not):
`-autoroll(er)?$`, `roller`, `(^|[-_])bot$`, `^bot-`, `(github|actions)-?bot$`,
`github-actions`. A login with an explicit role (`roles` or `people`) is not
matched by patterns, so a role fixes a false positive; `automationAuthors` and
`agentAuthors` win over roles.

Role resolution, first match wins: the repo's bot or any `[bot]` login →
`bot`; `agentAuthors` → `agent`; `automationAuthors` → `bot`; repo `roles`;
`people`; an `automationPatterns` match → `bot`; GitHub's
`authorAssociation` (`OWNER`, `MEMBER`, `COLLABORATOR` → `maintainer`); else
`external`. `bot` and `agent` comments are never human evidence: they're left
out of human totals, weights, reviewer counts, and theme counts.

## Command-line options

Every script prints its usage with `--help`. Unknown options exit `2`.

| Script | Option | Meaning |
|---|---|---|
| all three | `--config <path>` | user config file (default `$REVIEW_TUNER_CONFIG`, else `~/.config/review-tuner/config.json`) |
| `collect.dart` | `--repo <owner/name\|alias>` | target repository (collect, `guidance`; optional for `digest`, used for bot and roles) |
| | `--since <date>` / `--until <date>` | window of PR close dates, inclusive, UTC (`YYYY-MM-DD`, both or neither) |
| | `--days <n>` | window ending today (default 90) |
| | `--concurrency <n>` | parallel PR queries (default 4) |
| | `--max-chars <n>` | excerpt length in the digest (default 300) |
| | `--output-file <path>` | corpus JSONL path (collect), digest or select JSON (digest), guidance JSON (`guidance`) |
| | `--corpus`, `--stdout`, `--select`, `--path`, `--bot`, `--rebuttals` | digest options; see "Digest and `--select`" |
| | `--view`, `--no-acks`, `--max-bytes`, `--skip` | digest views and paging; see [Digest views and paging](#digest-views-and-paging) |
| `prepare.dart` | `--repo <owner/name\|alias>` / `--id <id>` | `init`: target repo and eval id |
| | `--eval <evalDir>` | `check` / `evaluate`: the eval directory |
| | `--runs <n>` | `check` only: runs per arm on the primary model (default 1) |
| | `--out <dir>` | run directory (default `<evalDir>/check` or `<evalDir>/evaluate`) |
| | `--seed <n>` | arm assignment (check/evaluate) or finding shuffle (judge) |
| | `--run <runDir>` | `judge`: the evaluate run directory |
| `score.dart` | `--run <runDir>` | the run directory to score (required) |
| | `--output-file <path>` | write the section's JSON (`all` also writes `<runDir>/score.json`) |

## Corpus (written by `collect.dart`)

One PR per line: its metadata (`number`, `title`, `url`, `mergedAt`,
`files`, ...), `author` with `authorRole`/`authorWeight`, `excludedReason`
(automation PRs, skipped by every summary), `truncated`, and `comments`. Each
comment has `kind` (`inline`, `review`, `issue`), `author`, `role`, `weight`,
`isPrAuthor`, `body`, and, when known, `path`, `line`, `commitId`, `threadId`
(the thread's first comment), `threadResolved`, and `severity`. Roles come
from the user config ([role resolution](#user-config)); bots and automation
accounts are `bot`, AI agent accounts `agent`. PRs by `bot` authors get
`excludedReason: automation-author`; PRs by `agent` authors are kept. `severity` is set
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
exclude PR authors' own comments. The window selects PRs by close date;
`createdRange` is the range of creation dates of the collected PRs (`null`s
when none were collected).

```json
{"repo": "o/n", "window": {"since": "…", "until": "…"},
 "createdRange": {"earliest": "YYYY-MM-DD", "latest": "YYYY-MM-DD"},
 "collectedAt": "…",
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
 "possibleAutomation": [{"login": "…", "authored": 160, "comments": 0}],
 "possibleAgents": [{"login": "…-agent", "authored": 3, "comments": 7}],
 "failedPrs": {"700": "<error>"},
 "humanCommentsTotal": 339, "humanCommentsWeighted": 285.25}
```

`possibleAutomation` and `possibleAgents` are hints over all collected PRs
(excluded ones too), listing only logins with no role, list entry, or pattern
match: `possibleAutomation` authored ≥ 10 PRs (or ≥ 20% of them, at least 3)
and wrote no substantive comment; `possibleAgents` end in `-agent` or
`[agent]`. Neither changes any count; confirm and add the login to
`automationAuthors` or `agentAuthors`, then collect again.

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
and `prs`. For big corpora, read the
[views](#digest-views-and-paging) instead.

`collect.dart digest --corpus <file> --select <regex> [--path <regex>]
[--bot [--rebuttals <ids|@file>]] [--output-file <x.json>]` counts comments in
non-automation PRs whose full body matches (case-insensitive; inline flags
like `(?i)` aren't supported); `--path` filters by comment path, also
case-insensitively (comments without a path never match it). It never writes
the digest files. A run with no matches exits 0 with `n: 0`; an invalid regex
exits 2. Every match has `match`: the first span the regex matched, with
about 40 characters of context on each side (`…` marks a cut), so you can
see why it matched (the markdown shows it under the match as `match:`).

**Human mode** (default): substantive human comments (not trivial like
"LGTM"; human replies in bot threads always count). `n`, `weighted`, `prs`,
and `reviewers` leave out comments by the PR's own author: those are still
listed in `matches` (with `isPrAuthor`) and counted as `prAuthorComments`.

```json
{"repo": "o/n", "corpus": "<path>", "select": "copyright", "path": "…",
 "comments": "human", "n": 2, "weighted": 2.0, "prAuthorComments": 0,
 "prs": [596, 663],
 "reviewers": [{"login": "pq", "role": "maintainer"}],
 "matches": [{"pr": 596, "author": "pq", "role": "maintainer", "weight": 1.0,
              "isPrAuthor": true, "kind": "inline", "path": "…", "line": 1,
              "commitId": "6e97ae9…", "text": "160-char excerpt",
              "match": "…context copyright context…",
              "url": "…#discussion_r123"}]}
```

**`--bot`**: the configured reviewer bot's comments only. `n` (= `inline`)
counts its matched **inline** comments and `prs` lists the PRs with one;
matched review summaries are listed in `matches` but only counted as
`reviewSummaries`. There is no `weighted`, `prAuthorComments`, or
`reviewers`. Quote `inline` as the bot's claim count. Each match lists its
human `replies` (`id`, the GitHub comment id; `author`, `role`, `isPrAuthor`,
`weight`, `url`, `text` up to 300 characters; the markdown shows each as
`↳ [r:<id>] who: text url`); `replies`, `repliesByRole` (role → count), and
`authorReplies` count them over all matches (each reply once), **including**
the PR author's.

The script doesn't decide which replies are rebuttals: you do, by reading
them. `--rebuttals <ids>` (only with `--bot`) takes the rebuttal reply ids,
comma-separated (`--rebuttals 123,456`) or as `@<file>` with one id per line;
in the file, `#` starts a comment, so note why each one is a rebuttal:

```text
# Platform floor rebuttals, 2026-10-13
3770997394  # #600 author: suggested API isn't available on the floor
4135974462  # #695 author: the class the bot named doesn't exist
```

Listed replies get `"rebuttal": true` (the others `false`), and the result
adds `rebuttals`, `authorRebuttals`, `rebuttalsByRole`, `rebuttalPrs`, and
`rebuttalWeight`, counted as in [rubric.md](rubric.md): at most one rebuttal
per (person, PR), weighted at the person's role weight, or role weight × 0.5
for the PR's author. `rebuttalReplies` is the number of listed replies
before that dedup. `otherReplies` lists the replies not listed (with `pr` and
`id`), so acceptances (counter-evidence) stay visible. An id that isn't a
reply to a matched bot comment exits 1 and names the unknown ids (the reply
may sit on a bot comment the `--select` regex doesn't match); a malformed or
missing ids file also exits 1, and a bad id on the command line exits 2.
Without `--rebuttals` there are no rebuttal numbers, and the markdown says
"classify replies: pass the rebuttal reply ids with --rebuttals".

```json
{"repo": "o/n", "corpus": "<path>", "select": "is invalid in Dart",
 "comments": "bot", "n": 2, "prs": [596], "inline": 2, "reviewSummaries": 1,
 "withHumanReply": 1, "resolved": 1,
 "replies": 2, "repliesByRole": {"maintainer": 2}, "authorReplies": 1,
 "rebuttals": 1, "rebuttalReplies": 1, "authorRebuttals": 1,
 "rebuttalsByRole": {"maintainer": 1}, "rebuttalPrs": [596],
 "rebuttalWeight": 0.5,
 "otherReplies": [{"pr": 596, "id": 125, "author": "…", "role": "maintainer",
                   "isPrAuthor": false, "weight": 1.0, "rebuttal": false,
                   "url": "…", "text": "Done."}],
 "matches": [{"pr": 596, "author": "gemini-code-assist[bot]", "role": "bot",
              "weight": 0.5, "kind": "inline", "path": "…", "line": 1,
              "commitId": "6e97ae9…",
              "humanReply": true, "authorReply": true, "resolved": true,
              "text": "160-char excerpt", "match": "…is invalid in Dart…",
              "url": "…#discussion_r123",
              "replies": [{"id": 124, "author": "pq", "role": "maintainer",
                           "isPrAuthor": true, "weight": 1.0,
                           "rebuttal": true, "url": "…#discussion_r124",
                           "text": "This is valid since Dart 3.8."}]}]}
```

The per-match `humanReply`/`resolved` (plus `authorReply`, set only when the
PR author replied) and `replies` appear only with `--bot`; `rebuttal` only
with `--rebuttals`; `isPrAuthor` (on matches), `path`, `line`, `commitId`,
and `url` only when known. `commitId` (also on digest comments and bot
threads; the markdown shows its first 10 characters as `@<sha>`) is the
commit an inline comment was made on: use it as a case's `commit`. A bot
comment has a human reply when a non-bot comment follows it in the same
review thread.

### Digest views and paging

`collect.dart digest --corpus <file> --view <full|bot-replies|human-inline>
[--no-acks] [--max-bytes <n> [--skip <k>]]` writes one view of the corpus
(non-automation PRs only), as JSON plus markdown, to
`<corpus base>.digest-<view>.json` / `.md` (`full`, the default, keeps the
`.digest.*` names and is the digest above, byte for byte). `--output-file`,
`--stdout`, and `--max-chars` work as for the digest; without `--stdout` it
prints a one-paragraph summary, the page line (when paging), and the paths.
None of these options combine with `--select`.

**`bot-replies`**: the configured bot's inline threads with at least one
human reply, by PR. Each thread has the bot comment's `id`, `path`, `line`,
`commitId`, `severity` (its badge, removed from `text`), `resolved`,
`outdated`, `text` (`--max-chars`), `url`, and `replies`: every human reply
with `id`, `author`, `role`, `weight`, `isPrAuthor`, `text` (3 × `--max-chars`),
`url`, and `ack: true` on bare acknowledgments. The markdown shows a thread as
`- [b:<id>] path:line @sha [severity, resolved]: text` and each reply as
`↳ [r:<id>] who [ack]: text`; the `r:` ids are the ones `--rebuttals` takes.
Totals: `botThreads`, `botThreadsWithHumanReply`, `threadsShown`,
`repliesShown`, `prsShown`.

`--no-acks` (only with `bot-replies`) drops threads whose human replies are
**all** bare acknowledgments, and adds `ackThreadsDropped` (count, also in the
summary) and `droppedThreads` (`pr`, thread `id`, reply ids) so the cut can be
audited. A reply is a bare acknowledgment when it is trivial (as for
substantive comments: "LGTM", "Thanks!", "Done."), or when, after removing
quoted lines (unless the whole reply is quoted, as in a `> [!NOTE]` callout),
links, `@mentions`, `#123` refs, and commit SHAs, it is empty (emoji or
punctuation only) or at most 12 words, all from a short list of
acknowledgments ("done", "fixed", "addressed", "applied", "thanks", "good
catch", "will do", "agreed", "yes", "ok", "+1", ...) and padding ("the",
"this", "in", "for", "commit", "suggestion", ...), with at least one
acknowledgment. Any other word keeps the reply, so "Done. Not needed here"
and "No." survive. It never decides what is a rebuttal (you do, with
`--rebuttals`): a surviving reply may still be an acceptance.

**`human-inline`**: substantive inline and review-body comments by humans
other than the PR author, by PR. Replies in the bot's threads (shown by
`bot-replies`) and conversation comments are left out. Each comment has `id`,
`kind`, `author`, `role`, `weight`, `path`, `line`, `commitId`, `reviewState`
(review bodies), `text` (`--max-chars`), and `url`. Totals: `comments`,
`weighted`, `inline`, `reviewBodies`, `byRole`, `paths`, `prsShown`. The
markdown lists the page's PRs, then groups the comments by path (most
comments first), then PR: `- #<pr> L<line> [c:<id>] who: text`, with review
bodies last.

**Paging.** `--max-bytes <n>` (any view) caps the markdown at `n` UTF-8
bytes: it stops at a PR boundary (always at least one PR) and ends with
`Showing PRs 1–k of N (budget n bytes). Next page: --skip k`, or
`Last page.`. `--skip <k>` starts after the first `k` PRs of the view (a
`--skip` past the last PR exits 2). A page holds whole PRs, so the pages of a
view cover each PR exactly once; `human-inline` groups by path within each
page. Every run rewrites the same `.md` (the current page); the JSON always
holds the whole view and is never truncated.

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
| `models` | first entry is the primary; results are reported per model, never pooled. Default: one run on the agent's own model (`inherit`). `check` always uses only the first model, with `prepare.dart check --runs N` runs per arm (default 1); `evaluate` uses every model and its `runs` |
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

## Guidance report (`collect.dart guidance`)

`collect.dart guidance --repo <repo> [--output-file <path>]` makes or updates
`head/`, a depth-1 clone of the default branch (clone killed after 5 minutes,
fetch after 2; a failure exits `1`), and prints what's in it. Read guidance
files from `head/` instead of fetching them one by one. JSON
(`--output-file`):

```json
{
  "repo": "owner/name",
  "head": "<dataDir>/owner/name/head",
  "commit": "<sha>",
  "agentFiles": [".gemini/styleguide.md", "AGENTS.md"],
  "agentRoots": [".gemini", "AGENTS.md"],
  "harnessGuidance": [{"path": ".gemini/styleguide.md", "present": true}],
  "contributionDocs": [".github/PULL_REQUEST_TEMPLATE.md", "CONTRIBUTING.md"],
  "linksChecked": 15,
  "brokenLinks": [
    {"file": ".gemini/styleguide.md", "line": 38, "target": "STYLE.md",
     "resolvesTo": ".gemini/STYLE.md"}
  ]
}
```

- `agentFiles`: every file under an [agent file](#agent-files) root.
  `harnessGuidance`: the config's `harness.guidance` paths.
  `contributionDocs`: `PULL_REQUEST_TEMPLATE.md` and `CONTRIBUTING.md` at the
  root or in `.github/` (any case).
- Links are checked in the markdown (`.md`, `.mdc`) agent and guidance files:
  inline and reference-style links, outside code spans and fenced blocks,
  resolved from the linking file's directory (`/...` from the repo root).
  URLs with a scheme and `#anchor`-only links are skipped; anchors aren't
  checked. A link that escapes the repo counts as broken.

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
               "lostFlagCases": []},
   "matches": [{"case": "pr612", "arm": "baseline", "run": 2,
                "comments": [{"severity": "high", "path": "…", "line": 1051,
                              "text": "first 120 chars of title: body"}]}]}},
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

`replay.<model>.matches` lists, for every run that flags the concern, the
comments that matched (the markdown shows them as "Matched comments"); use
it to check that the concern regexes catch only what they should.
`noise` is present once the judge has run; `fidelity` when `eval.json` sets
`corpus` (`{"bot", "measurable": false}` when the bot's comments carry no
usable severity or tag; no `models` when the bot flagged nothing).
