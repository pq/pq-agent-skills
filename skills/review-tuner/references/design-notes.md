# Design notes

review-tuner grew out of a pilot on `flutter/dart-intellij-third-party`
(October 2026). Its first suggestion narrowed an over-broad style-guide rule.
Gemini Code Assist had posted 7 `[MUST-FIX]` comments on legitimate edits, and
a maintainer dismissed them. The pilot replays took that from 13/18 wrong flags
to 1/18 on the primary model, and to 0/12 on two other models.

The goals are **simplicity**, **generality** (any repo, any review bot),
and **configurability** (a cheap path and a thorough path).

## Complexity backed out

| Backed out | Pilot had | Now | Why it's OK |
|---|---|---|---|
| Two flag metrics (strict + narrow) | both reported | one flag rule from `eval.json` | strict was always the primary metric |
| Sealed arm key file | `arms-key.json` | neutral `arm1`/`arm2` dirs; mapping in `tasks.json` | reviewers never see the mapping; the orchestrator isn't blind anyway |
| "B-then" arm (guidance as of PR time) | specified | removed | never needed; fidelity uses the current baseline |
| Baseline result caching, state file | specified | removed | reruns are cheap at this scale |
| Pinned primary model + mandatory robustness models | required | `models` list in `eval.json`; default one run on the agent's model | in the pilot, extra models confirmed the direction but never changed a decision, and the "primary" model matched the real bot least |
| Separate local-review harness | special case | a harness is a guidance file list (one reviewer prompt) | one code path |
| Three-way matching (bot / baseline / candidate) | specified | fidelity = baseline recall of the bot's real comments | that's the part that was actually used |
| Result extraction from agent transcripts | 2 Python scripts | reviewers write their own result files | agent-neutral, no scraping |
| Agent-specific workflow orchestration | planned | plain task manifest | works on any agent with subagents |
| Repo checkouts for every run | always | `evaluate` only; `check` is diff-only | diff-only runs gave the same verdicts in the pilot (small n) |
| Hand-coded roles | enum in the collector | config `roles` → `people` → GitHub `authorAssociation` | works on any repo with zero config |
| Reactions on comments | collected per comment | not collected | no step or rubric row read them |
| Commits and review rounds | commit list, `postReviewCommits` | not collected | a weak proxy (force-pushes hide rounds) that nothing used |
| Frequent-contributor weighting | `frequent` role with its own weight and thresholds | removed; stats list unconfigured frequent participants instead | two places set the weight, and no result depended on it (see Future research) |
| Replay extras | flags in other path groups, kept comments per negative, flagged run numbers | removed | informational only; noise and the flag rule already cover them |

## Known gaps

- Held-out selection is manual (the agent picks cases; a blind selector was
  specified but not built).
- `remove` evals that delete a whole guidance file aren't supported (the
  candidate overlay can only add or replace files). Removing a rule *within*
  a file works.
- PRs that edit agent files themselves aren't rejected automatically. The
  files are stripped from checkouts, but the edits still appear in the diff,
  so avoid such PRs as cases.
- The collector reads the first 100 items per PR connection (files, threads,
  comments) and flags truncation rather than paginating.
- No interaction check when several suggestions land together.
- Fidelity is recall only. When the bot flagged every in-scope file, it can't
  tell a faithful simulator from one that flags everything.
- Models report their own identity; versions aren't verified.

## Future research

- **Weighting frequent external contributors.** An earlier version gave
  active external contributors (by PRs authored or comments written in the
  window) a weight between `external` and `maintainer`. It was removed for
  simplicity. It could return once evidence shows it changes outcomes, for
  example a theme whose Evidence level differs with and without the bump.
  Calibrating it would need such cases: thresholds and the weight should be
  chosen so known-trusted contributors land above `external` without
  letting volume alone outweigh a maintainer. Until then, the stats' list of
  unconfigured frequent participants lets the user assign a role explicitly.
