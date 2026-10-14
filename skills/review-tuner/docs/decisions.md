---
audience: maintainers and agents changing the skill
purpose: decision log - what was decided, why, and what replaced it; plus the complexity deliberately backed out of the pilot
kept-current-by: AGENTS.md rules + tool/check_docs.dart (links, decision ids)
---

# Decisions

D1–D30 come from the original design (pilot era), restated generically.
D31+ were made while building and testing the skill. Ids are never reused;
an obsolete decision stays, marked `superseded by` or `withdrawn`. Evidence
behind many of these is in [lessons.md](lessons.md).

## Original design (D1–D30)

### D1: Simulate the review bot with reviewer subagents, several runs per arm
Rates come from per-run data; coalesced views are for reading only.

Status: superseded by D33

### D2: Weight maintainers higher; label non-maintainer evidence
Non-maintainer comments count, at a lower weight, and reports name the role.

Status: accepted

### D3: Every suggestion carries a confidence rubric level
The rubric ([references/rubric.md](../references/rubric.md)) is versioned and tuned over time.

Status: accepted

### D4: All agent files are in scope; repos are treated separately
Style guide, bot config, `AGENTS.md`, rules, skills. No shared cross-repo guide; cross-repo patterns are only noted.

Status: accepted

### D5: Draft PRs only in the user's fork; the user opens upstream PRs
Never write to the target repo.

Status: accepted

### D6: On demand first; scheduled runs later
Status: accepted

### D7: One copy of the skill, inside the pilot repo
Status: superseded by D27

### D8: Compare simulated reviews with the bot's real comments on every eval PR
Status: superseded by D35

### D9: Run data lives in a personal data dir, never in the skill
Configurable `dataDir`; personal data never enters the skill's directory.

Status: accepted

### D10: Pinned Pro-class primary model plus mandatory robustness models; never pool
Status: superseded by D34

### D11: No real-bot replays on personal accounts and no billing-bearing setup
The skill never creates cloud projects, enables billing, installs apps, or uses API keys.

Status: accepted

### D12: Baseline = guidance on the default branch today; PR-time guidance only for fidelity
Status: superseded by D35

### D13: A bot-mode harness (bot's files only) next to a local-review harness
Status: superseded by D33

### D14: Include PRs closed without merging
Rejection reasons are often the clearest statement of a rule.

Status: accepted

### D15: Initial role weights: maintainer 1.0, everyone else 0.5
Status: superseded by D22

### D16: Measure review density before mining; widen the window if sparse
`propose` warns below 20 PRs with substantive human comments or 50 human comments.

Status: accepted

### D17: Pilot on one repo, prototyped outside it; build the skill only if it pays off
Status: accepted

### D18: Fixed pilot window so reruns are reproducible
The skill keeps explicit `--since`/`--until` for the same reason.

Status: accepted

### D19: Scripts in standalone Dart (`dart:io`/`dart:convert` only); configs in JSON
Status: accepted

### D20: Pilot roster of named people per role
Status: superseded by D28

### D21: Maintainers weigh the same; single-reviewer evidence is labeled, not capped
No special cap for the operator. The High row's "≥2 PRs" already guards against one opinion.

Status: accepted

### D22: Extra roles at 0.75 and a frequent-external-contributor bump
Status: superseded by D48

### D23: Keep a severity tier the bot hides because local reviews use it
A pilot-repo guidance decision, not a skill decision.

Status: withdrawn

### D24: Unresolved policy questions go to an issue, not a guidance PR
The skill proposes guidance for settled policy; it doesn't decide policy.

Status: accepted

### D25: Take the first suggestion (P0-1) end to end before generalizing
Status: accepted

### D26: Reports and PR bodies open with a plain-language Summary
The issue, then replay results and confidence, with no jargon. Every number matches the tables.

Status: accepted

### D27: Home is this skills repo; goals are simplicity, generality, configurability
Agent-neutral; verified on Jetski and Antigravity. The target repo is a per-run choice.

Status: accepted

### D28: One user config file; role lookup repo roles → people → GitHub association
`$REVIEW_TUNER_CONFIG` or `~/.config/review-tuner/config.json`. Works with no config.

Status: accepted

### D29: Three modes: propose, check, evaluate
`propose` has no replays (at most Medium); `check` is a quick replay with a helps / no effect / hurts verdict; `evaluate` is thorough with the full rubric.

Status: accepted

### D30: Named review-tuner (formerly guide-tuner)
The input is review feedback, and replays test only reviewer behavior.

Status: accepted

## Building and testing the skill (D31+)

### D31: Agent-neutral fan-out through files
`prepare.dart` writes `tasks.json`; each worker gets a one-line message pointing at its own prompt and **writes its own result file**. No transcript scraping, no agent-specific orchestration.

Status: accepted

### D32: Blinding by neutral arm dirs
Workers see `arm1`/`arm2`; the mapping lives only in `tasks.json`, which workers are told not to read. The orchestrator isn't blind; scoring is deterministic instead.

Status: accepted

### D33: One harness = one fixed reviewer prompt + a list of guidance files
Per-repo `harness.guidance` (default: the Gemini Code Assist files). `affects` (`bot`/`both`/`local`) says which readers a change reaches. One code path.

Status: accepted

### D34: Models are a list in eval.json; default one run on the agent's own model
Extra models are an optional robustness check that can only lower a level. Results are never pooled across models.

Status: accepted

### D35: Fidelity = baseline recall of the bot's real comments, evaluate only
No PR-time guidance arm. If the bot's comments carry no recognizable severity, fidelity is "not measurable".

Status: accepted

### D36: One typed corpus model shared by all scripts
`PullRequest`/`Comment` with enums and records replace parallel map-based code. Costs lines; accepted for one definition of "substantive", "bot", and "reply to bot".

Status: accepted

### D37: The judge pools the primary model's findings only
Noise is scored on the primary model, so judging other models' findings would be wasted work.

Status: accepted

### D38: Noise Reject cut-off at more than +1.0 per run per PR on negatives
About one extra bad comment per PR per run, well above the ±0.5 swing seen in the pilot. +0.33 to +1.0 is Low. To be recalibrated ([roadmap.md](roadmap.md)).

Status: accepted

### D39: Losing a want=flag case caps Replay at Low
It doesn't make the verdict `hurts` or Reject on its own; the verdict follows the overall correct rate.

Status: accepted

### D40: Every flagged run lists the comment that matched; read them before a verdict
If a match isn't about the concern, tighten the regex and re-score; no new runs needed.

Status: accepted

### D41: PR authors' rebuttals of the bot count, at half their role weight
One rebuttal per person per PR. Most pushback against the bot comes from authors.

Status: accepted

### D42: The agent classifies rebuttals; the script counts them
The agent writes reply ids with reasons to a file; `--rebuttals @file` applies the weights. A regex classifier was tried and dropped (~10–30% recall).

Status: accepted

### D43: Bot claim counts are inline comments only
Review summaries are listed and counted separately; no weighted sum for bot comments.

Status: accepted

### D44: Counter-evidence: accepted ≥ rebutted caps a "bot is wrong" theme at Low
Unreplied but verifiably wrong bot comments are context or support a `fix`, never weighted evidence.

Status: accepted

### D45: check is diff-only, primary model, `--runs N` (default 1)
Diff-only runs gave the same verdicts as checkouts in the pilot (small n). `--runs` raises confidence in a check without a full evaluation.

Status: accepted

### D46: Diffs are computed from the PR's own base, not the default branch
In merge-commit repos the reviewed commit is already in the default branch, so the diff would be empty.

Status: accepted

### D47: Every score subcommand validates first and refuses partial results
Exit 1 for invalid data (including judge outputs), exit 2 only for bad arguments. A failed query is never "no results".

Status: accepted

### D48: Weights are one config map; frequent-contributor weighting removed
No result depended on it, and it was set in two places. Stats list unconfigured frequent participants so the user can assign a role ([roadmap.md](roadmap.md)).

Status: accepted

### D49: One shared agent-file list, used by the audit and stripped from checkouts
Matched recursively by basename, so nested `AGENTS.md` and `.gemini/` don't leak into replays.

Status: accepted

### D50: Theme counts leave out PR authors' own comments
Shown separately; otherwise authors inflate Evidence and break "single-reviewer" labels.

Status: accepted

### D51: The audit resolves links from the linking file and assumes the bot doesn't follow them
Rules that live only in linked files are flagged as invisible to the bot. Empty code search is inconclusive.

Status: accepted

### D52: A deterministic fix is High by inspection, however many reviewers raised it
Two files disagree, or a referenced symbol doesn't exist. Reports say "by inspection, not replay".

Status: accepted

### D53: `gh` retries only transient errors, briefly, with a per-call timeout
Secondary rate limits, HTTP 5xx, and timeouts get 3 retries (2, 4, 8 s); each call is killed after 120 s. The primary rate limit fails at once with a hint, since it resets within the hour ([lessons.md](lessons.md)).

Status: accepted

### D54: The audit reads a shallow clone, not the contents API
`collect.dart guidance` keeps a depth-1 clone of the default branch at `<repoDir>/head/` (git under timeouts) and lists agent files, harness guidance, contribution docs, and broken relative links (D51). Agents read files there.

Status: accepted

## Complexity backed out

What the pilot had and the skill deliberately dropped. Bring something back
only with evidence that it changes an outcome.

| Backed out | Now | Why it's OK |
|---|---|---|
| Two flag metrics (strict + narrow) | one flag rule from `eval.json` | strict was always the primary metric |
| Sealed arm key file | neutral arm dirs (D32) | reviewers never see the mapping |
| Arm with guidance as of PR time | removed (D35) | never needed; fidelity uses the current baseline |
| Baseline result caching, state file | removed | reruns are cheap at this scale |
| Pinned primary + mandatory robustness models | `models` list (D34) | extra models never changed a pilot decision |
| Separate local-review harness, configurable prompt | one prompt + file list (D33) | one code path |
| Three-way bot / baseline / candidate matching | baseline recall (D35) | the only part actually used |
| Result extraction from transcripts; agent-specific workflows | files + task manifest (D31) | works on any agent with subagents |
| Repo checkouts for every run | `evaluate` only (D45) | same verdicts diff-only in the pilot |
| Hand-coded role enum | config lookup chain (D28) | zero-config on any repo |
| Reactions, commit lists, review rounds | not collected | nothing read them; rounds are a weak proxy |
| Frequent-contributor weight | removed (D48) | no result depended on it |
| Replay extras (other path groups, kept comments per negative, run lists) | removed | informational only |
