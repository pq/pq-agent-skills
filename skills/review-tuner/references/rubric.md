# Confidence rubric

`score.dart rubric` computes these rows; this page explains them. Thresholds are
constants at the top of `scripts/score.dart`. The rubric is a structured
judgment over small samples, not a statistical test, and reports say so.

Metrics are candidate minus baseline, per case set, on the **primary** model.

| Level | Evidence | Replay | Noise |
|---|---|---|---|
| **High** | ≥3 weighted comments, ≥2 PRs, ≥1 maintainer; or a `fix` backed by a deterministic contradiction | held-out improvement ≥ 0.5 and consistency ≥ 2/3 | no increase on negatives |
| **Medium** | ≥2 weighted comments, or 1 maintainer comment of a general nature | motivating improvement ≥ 0.5; held-out positive or absent | increase ≤ 0.33 per PR |
| **Low** | one comment, or non-maintainers with < 2 weighted comments | some improvement | increase ≤ 1.0 per PR |
| **Reject** | — (Evidence never goes below Low) | none, or worse | increase > 1.0 per PR |

- **Improvement** means a rise in the share of runs with the correct outcome
  (`want: flag` and flagged, or `want: no-flag` and not flagged).
- **Consistency** is the share of held-out cases the candidate gets right in
  at least 2/3 of their runs (`consistencyShare` in `scripts/score.dart`; the
  same constant sets the High threshold, and reports show it as 67%).
- **Noise** is the mean number of findings the blind judge rated `noise` or
  `wrong`, per run per PR (`evaluate` only), compared on the negative controls.
  With 3 negatives × 3 runs, one extra junk finding moves it by about 0.11, so
  the Reject cut-off (+1.0) means roughly one extra bad comment per PR per run.
  It's set well above the run-to-run variation seen in the pilot (±0.5). The
  judge doesn't see the style guide, so guide-mandated nits can read as noise.

Modifiers and special cases:

- **Losing a `want: flag` case:** if the candidate's correct rate on any
  `want: flag` case is below the baseline's, Replay is capped at **Low** and
  the row says which case. It doesn't make the verdict `hurts` or Reject on its
  own: the verdict comes from the change in the overall correct rate.
- **Motivating PRs only:** capped at Medium (you told the reviewer what to look
  for, so of course it finds it).
- **`fix` by inspection:** a deterministic contradiction (two files disagree, a
  referenced symbol doesn't exist) can be High without replay. The report says
  "verified by inspection, not replay". In `score.dart rubric`, `"type": "fix"`
  with `evidence.contradiction: true` sets the Evidence row to High however
  many comments back it (the other rows still apply).
- **Evidence floor:** the Evidence row is at least Low. In `evaluate`, a
  missing `evidence` block in `eval.json` is an error (exit 1); in `check`
  it reads as Low.
- **Evidence from rebuttals of the bot** ("the bot is wrong" themes): the
  evidence is bot comments a human pushed back on (`collect.dart digest --select ... --bot`
  counts the replies by role, PR authors included). Replies aren't rebuttals
  until you've read them. A rebuttal by the PR's author counts at **role
  weight × 0.5** (so 0.5 for a maintainer author); other reviewers' rebuttals
  count at their role weight.
- **Count each human comment once.** A non-author's rebuttal found with
  `--bot` is often already in the human-mode `--select` count for the same
  theme: don't add it again. At most one rebuttal counts per (person, PR,
  reason); pasting the same pushback on 10 threads is one. Count only the
  comments that support the proposed text: split a heterogeneous theme rather
  than pooling its comments.
- **Counter-evidence** ("the bot is wrong" themes): also count the bot
  comments of the same kind that humans accepted ("Done", applied the
  change). If accepted ≥ rebutted, the Evidence row is capped at **Low** and
  the next step is `evaluate`. Bot comments that are verifiably wrong but got
  no reply may be cited as context, or support a `fix` by inspection when
  they contradict a repo fact, but are never counted as weighted evidence.
- **Fidelity:** if baseline runs reproduce < 40% of the bot's real comments on
  the motivating PRs, `affects: bot|both` suggestions drop one level. If the
  bot's comments carry no recognizable severity or tag, fidelity is "not
  measurable for this bot" and no modifier applies.
- **Robustness (optional extra models):** if any extra model shows the
  candidate not helping, drop one level. It can only lower a level.
- **Single-reviewer evidence** is labeled, not capped; the High row's "≥2 PRs"
  already guards against one person's opinion.
- **`propose` mode** has no replay: at most Medium, except `fix` by inspection,
  which is High however many reviewers raised it.
- **`evaluate` without noise data** (no judge run, or no judged negatives) is
  an error, not a skipped row.
- **`check` mode** gives helps / no effect / hurts, not a level: the sign of
  the change in the per-run correct rate over all scored cases.
