---
audience: agents and people changing the review-tuner skill (not agents running it; they read SKILL.md)
purpose: entry point for changing the skill safely and keeping its design docs current
kept-current-by: AGENTS.md rules + tool/check_docs.dart (links, decision ids)
---

# Changing review-tuner

**Running** the skill? Read [SKILL.md](SKILL.md) instead; this file is for
**changing** it.

## Read first

1. [docs/README.md](docs/README.md): what each design doc is for.
2. [docs/decisions.md](docs/decisions.md): why things are the way they are.
   Check here before "simplifying" something; it may be deliberate.
3. [docs/lessons.md](docs/lessons.md): mistakes already made once.
4. [docs/roadmap.md](docs/roadmap.md): planned work and known gaps.

## Layout

| Path | Layer | Loaded when the skill runs? |
|---|---|---|
| `SKILL.md`, `prompts/`, `references/`, `templates/` | runtime: instructions, formats, rubric, templates | yes |
| `scripts/` (+ `scripts/src/`) | runtime: `collect`, `prepare`, `score` and shared code | run by the agent |
| `docs/`, `AGENTS.md` | design: how and why | no |

## Change safely

- **Format and analyze** from the repo root: `dart format skills/review-tuner`
  and `dart analyze .` (must be clean). Scripts use `dart:io`/`dart:convert`
  only (D19).
- **Keep contracts in sync.** A new or changed option, field, or file goes in
  [references/formats.md](references/formats.md); a rubric change goes in
  [references/rubric.md](references/rubric.md) and the constants at the top of
  `scripts/score.dart`.
- **P0-1 regression** (needs the pilot data in your data dir; no model runs):

  ```
  dart skills/review-tuner/scripts/score.dart all \
    --run <dataDir>/flutter/dart-intellij-third-party/evals/p0-1-third-party/evaluate
  ```

  Expect, on `pro`: motivating false flags 6/9 → 1/9, held-out 7/9 → 0/9,
  guard 3/3 → 3/3; noise on negatives 1.33 → 0.83; fidelity 10/21 (48%);
  `flash` and `claude` 6/6 → 0/6; **Overall: High**. Any change to these
  numbers needs an explanation.
- **Diff path changes** (anything in `prepare.dart` that builds diffs or
  checkouts) need a small `check` smoke test with real runs; the regression
  above only re-scores existing results.
- **Docs check:** once `tool/check_docs.dart` exists in the repo, run
  `dart tool/check_docs.dart`; it checks front matter, relative links, and
  decision ids.
- **Privacy:** this repo is public. No reviewer names (say "a maintainer" or
  "an external contributor"), no role labels for named people, no personal
  paths (`<dataDir>` instead), no internal links.

## Keep the docs current

- **Behavior changed?** Add a decision to [docs/decisions.md](docs/decisions.md)
  (`### D<next>: <title>` + `Status: accepted`). If it replaces an old one,
  set the old one to `Status: superseded by D<next>`. Never renumber or delete.
- **Learned something non-obvious** (a surprise, a failed approach, a number
  that changed your mind)? Add it to [docs/lessons.md](docs/lessons.md) with
  its evidence and its consequence.
- **Finished a roadmap item?** Remove it from [docs/roadmap.md](docs/roadmap.md)
  and record the choice as a decision.
- **New limitation?** Add it to the roadmap's Known gaps, and to SKILL.md's
  Limitations if users need to know at run time.
- Keep docs distilled: a decision is a few lines, not a spec.
