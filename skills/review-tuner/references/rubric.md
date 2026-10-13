# Confidence rubric (v0)

`score.dart rubric` computes these rows; this page explains them. Thresholds are
constants at the top of `scripts/score.dart`. The rubric is a structured
judgment over small samples, not a statistical test, and reports say so.

Metrics are candidate minus baseline, per case set, on the **primary** model.

| Level | Evidence | Replay | Noise |
|---|---|---|---|
| **High** | ≥3 weighted comments, ≥2 PRs, ≥1 maintainer | held-out improvement ≥ 0.5 and consistency ≥ 0.66 | no increase on negatives |
| **Medium** | ≥2 weighted comments, or 1 maintainer comment of a general nature | motivating improvement ≥ 0.5; held-out positive or absent | increase ≤ 0.33 per PR |
| **Low** | one comment, or non-maintainers only | some improvement | increase ≤ 1.0 per PR |
| **Reject** | — | none, or worse | increase > 1.0 per PR |

- **Improvement** means a rise in the share of runs with the correct outcome
  (`want: flag` and flagged, or `want: no-flag` and not flagged).
- **Consistency** is the share of held-out cases the candidate gets right in
  at least 2 of 3 runs.
- **Noise** is the mean number of findings the blind judge rated `noise` or
  `wrong`, per run per PR (`evaluate` only), compared on the negative controls.
  With 3 negatives × 3 runs, one extra junk finding moves it by about 0.11, so
  the Reject cut-off (+1.0) means roughly one extra bad comment per PR per run.
  It's set well above the run-to-run variation seen in the pilot (±0.5). The
  judge doesn't see the style guide, so guide-mandated nits can read as noise.

Modifiers and special cases:

- **Motivating PRs only:** capped at Medium (you told the reviewer what to look
  for, so of course it finds it).
- **`fix` by inspection:** a deterministic contradiction (two files disagree, a
  referenced symbol doesn't exist) can be High without replay. The report says
  "verified by inspection, not replay".
- **Fidelity:** if baseline runs reproduce < 40% of the bot's real comments on
  the motivating PRs, `affects: bot|both` suggestions drop one level.
- **Robustness (optional extra models):** if any extra model shows the
  candidate not helping, drop one level. It can only lower a level.
- **Single-reviewer evidence** is labeled, not capped; the High row's "≥2 PRs"
  already guards against one person's opinion.
- **`propose` mode** has no replay: at most Medium, except `fix` by inspection,
  which is High however many reviewers raised it.
- **`check` mode** gives helps / no effect / hurts, not a level.
