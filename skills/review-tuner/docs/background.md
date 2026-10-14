---
audience: users and new maintainers
purpose: why review-tuner exists, the pilot that motivated it, what the first runs found, and what it can and can't prove
kept-current-by: AGENTS.md rules + tool/check_docs.dart (links, decision ids)
---

# Background

## The problem

Repositories now carry guidance for AI agents: a review bot's style guide
(e.g. `.gemini/styleguide.md` for Gemini Code Assist), `AGENTS.md`, rules,
skills. That guidance drifts. Rules get too broad, files contradict each other,
and the things human reviewers enforce by hand never make it into the files the
bot reads. Nobody notices until the bot posts the same wrong comment for the
tenth time.

The evidence to fix this already exists: **what human reviewers actually said
in pull requests**, including how they answered the bot. review-tuner mines
that history, proposes small guidance changes backed by PR links and
script-produced counts, and can replay old PRs to test whether a change would
have helped.

## The pilot (P0-1)

The skill grew out of a pilot on `flutter/dart-intellij-third-party`
(October 2026).

- **The issue.** The style guide told the review bot to flag *any* edit under
  `third_party/thirdPartySrc/` as `[MUST-FIX]`. Only two subtrees there are
  copied from upstream; the rest is maintained in the repo. Another PR had
  already narrowed `.aiconfig` and the local review skill, but not the file
  the bot reads. The bot posted 7 `[MUST-FIX]` comments on legitimate edits
  across #612, #614, and #615; a maintainer dismissed all of them.
- **The change.** Narrow that one bullet to the copied paths.
- **The replay.** 10 cases (9 real PRs, 1 synthetic guard), blind reviewers,
  current guide vs. proposed guide, at the commits the bot actually reviewed:

| Model | Wrong third-party flags: current → proposed | Guard (real copied file) still flagged |
|---|---|---|
| Gemini Pro-class (primary, 3 runs) | 13/18 → **1/18** | 3/3 |
| Gemini Flash-class (1 run) | 6/6 → **0/6** | 1/1 |
| Claude (1 run) | 6/6 → **0/6** | 1/1 |

On the two extra models together that's 12/12 → 0/12. A blind judge rated all 19 of the current guide's flags on allowed paths as
*wrong*, and the proposed guide added no noise on unrelated PRs. Confidence:
**High** (single-reviewer evidence, backed by a file contradiction).

The pilot worked, but it was hand-built: Python glue scraping agent
transcripts, a sealed arm key, a pinned model, many one-off scripts. The skill
keeps the method and drops most of that machinery
([decisions.md](decisions.md#complexity-backed-out)).

## First runs on three repos

`propose` mode (no replays) on `flutter/devtools`, `flutter/flutter`, and
`flutter/dart-intellij-third-party` took about 10 minutes per repo and found:

- **One High-by-inspection fix per repo**, no replay needed: broken relative
  links that hid most rules from the bot; a doc-comment rule stricter than the
  analyzer config; a wrong package name and a stale platform floor.
- **Recurring human corrections the bot never makes**, e.g. redirecting
  Material/Cupertino changes to another repo (19 comments, 9 PRs, 8 maintainers).
- **Cross-repo patterns:** the bot calls valid modern code (new language
  features, packages, SDK versions) an error; important rules live in files
  the bot doesn't read; changelog conventions are enforced by hand.

`check` mode (quick replays, mostly 1 run per case on Flash) then tested nine
suggestions:

| Result | Examples |
|---|---|
| Helps | Material/Cupertino redirect 2/6 → 6/6 correct runs; shared-helper names 4/6 → 6/6 |
| Hurt, then fixed | A release-note rule was stricter than maintainers (6/6 → 5/6). Narrowed, re-checked with 3 runs: 15/18 → 18/18 |
| Distorted by a regex | A gating rule looked mixed until the concern pattern was tightened: 6/18 → 15/18 |
| No signal | "Stop false compile claims" and a doc-scope fix: the simulator didn't reproduce the bot's mistakes from a diff alone |

The lessons from these runs shaped the current skill; see [lessons.md](lessons.md).

## Prior art (short)

| Idea | Where it comes from | How it's used here |
|---|---|---|
| A/B replay with held-out cases and negative controls | standard prompt and model evaluation practice | `evaluate` mode; motivating PRs alone are capped at Medium because they're circular |
| Blind LLM judge | LLM-as-judge evaluation | Rates findings as valid / noise / wrong without knowing the arm |
| Decision records with status | Architecture Decision Records | [decisions.md](decisions.md) |
| A file agents read first | `AGENTS.md` convention | [../AGENTS.md](../AGENTS.md), for agents changing this skill |

## What it can and can't prove

**Can:**

- Show, with links and counts, which rules humans keep enforcing or rejecting.
- Find contradictions and stale references deterministically.
- Show that a guidance change shifts a *simulated* reviewer's behavior on real
  PRs, per model, with sample sizes.

**Can't:**

- Replay the real bot. Replays use a fixed reviewer prompt over the bot's
  guidance files; `evaluate` measures how much of the bot's real comments that
  simulator reproduces (recall only).
- Prove changes aimed at coding agents (`affects: local`); only reviewer
  behavior is replayed.
- Give statistics. Samples are small; results are structured judgments.
- Test claims that depend on repo context the reviewer can't see (e.g.
  "this API doesn't exist") in `check` mode, which is diff-only.

Open questions and planned work: [roadmap.md](roadmap.md).
