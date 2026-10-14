---
audience: users and maintainers
purpose: open questions, known gaps, and future work, so limitations are explicit and the next piece of work is easy to pick up
kept-current-by: AGENTS.md rules (finished items move to decisions.md) + tool/check_docs.dart (links, decision ids)
---

# Roadmap

When an item ships, delete it here and record the choice in
[decisions.md](decisions.md).

## Open questions

**Which model best simulates the review bot?**
On P0-1 the Pro-class model under-reproduced the bot (48% of its comment
locations vs. 100% for Flash and Claude, at 1 run each), but on a doc-scope
check Pro was the only one to reproduce the bot's demand
([lessons.md](lessons.md)). To answer it:

- Build a fidelity set where the bot flagged some files and left others alone,
  so precision can be measured, not just recall.
- Run ≥3 runs per model; pick the closest as the default per repo; revisit
  when models change.
- Run extra models only when they could change the outcome (near a rubric
  threshold, wording-dependent rules, or replay as the only evidence of harm).

**Is the noise Reject cut-off right?**
+1.0 per run per PR (D38) was set from one pilot. Revisit once a few more
`evaluate` runs show typical variance.

**Are the role weights and rubric thresholds right?** Both are v0. A
calibration loop (below) would answer this from outcomes.

## Known gaps

- **Held-out selection is manual.** A selector blind to the motivating
  comments was designed but not built.
- **Removing a whole guidance file** can't be evaluated (the candidate overlay
  only adds or replaces files). Removing a rule within a file works.
- **PRs that edit agent files** aren't rejected automatically; avoid them as cases.
- **Collection reads the first 100 items** per PR connection (files, threads,
  comments) and flags truncation instead of paginating.
- **No interaction check** when several suggestions land together.
- **Fidelity is recall only** (D35).
- **Model identity is self-reported**; versions aren't verified.
- **Cross-repo patterns** are spotted by hand in reports, not by the scripts.

## Next batch

| Item | Why | Evidence |
|---|---|---|
| Digest views (`bot-replies`, `human-inline`, threads with pushback) and a size budget | Digests of 130–577 KB take several reads | all three exploration repos |
| A ready-to-run dispatch list from `prepare.dart` (`message`, `tier` pairs) | Scripted orchestrators couldn't parse `tasks.json` from a file read | exploration check runs |

## Future work

- **Rubric calibration loop.** Track which suggestions merge or get rejected
  and tune thresholds and weights from that. Needs a small outcome record
  (a state file was backed out of v0).
- **Frequent-contributor weighting**, only if a case shows the Evidence level
  changing with it (removed in D48).
- **Scheduled runs** (e.g. monthly) producing a digest instead of PRs (D6).
- **Real-bot confirmation** for High-confidence finalists, in a sandbox repo
  owned by a team that already runs the bot. Never on a personal billing
  account (D11).
- **Refine the reviewer prompt** from fidelity numbers over time.
- **More repos and more bots.** Other bots need only a guidance file list and,
  for fidelity, a way to read severity from their comments.
- **A shared base guide** across related repos, seeded by recurring
  cross-repo patterns (separate project; D4).

## Alternatives considered and not chosen

| Alternative | Why not | Revisit when |
|---|---|---|
| Pooling models into one rate | Less like the bot; muddies attribution | Never for the primary metric |
| Testing only on motivating PRs | Circular | Never as the sole evidence |
| Fully automatic PRs | Rubric isn't calibrated | After calibration; fork PRs only, High only |
| One copy of the skill per target repo | Copies drift, like the guides did | If discoverability becomes a real problem |
