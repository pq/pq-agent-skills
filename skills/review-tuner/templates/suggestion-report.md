# {{id}}: {{title}}

**Repo:** `{{repo}}` · **Type:** {{type}} · **Affects:** {{affects}} · **Confidence: {{level}}**

## Summary

**The issue.** <What the guidance says today, why that's wrong or missing,
and the concrete harm, e.g. "N dismissed bot comments across PRs #a, #b".>

**Replay and confidence.** <Plain language, no internal labels like "arm" or
"Δ". A few bullets: before → after per model, guard preserved or not, noise
impact.>

**Confidence: {{level}}.** Caveats:
- <top 2-3 caveats>

## Change

```diff
<the exact diff>
```

## Evidence

| Source | What it shows | Who (role) |
|---|---|---|

<Label single-reviewer evidence.>

## Replay

<Per model, never pooled: the score.dart replay table with sample sizes
(n PRs, n runs). Mode: check or evaluate.>

## Noise (evaluate only)

<score.dart noise table; note what the judge could and couldn't see.>

## Fidelity (evaluate only)

<score.dart fidelity: share of the bot's real comments reproduced, with the
recall-only caveat if it applies.>

## Rubric

<score.dart rubric rows, one justification each.>

## Limitations

- The simulator isn't the real bot (fidelity above). Samples are small.
- <anything else: partial-context runs, sequential runs, judge blind spots>

## Raw artifacts

`<dataDir>/<owner>/<repo>/evals/{{id}}/` (eval.json, tasks.json, results/, judge/, score.json)
