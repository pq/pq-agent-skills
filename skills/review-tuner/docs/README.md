---
audience: anyone opening this folder (users, maintainers, agents refining the skill)
purpose: index of the review-tuner design docs - what each one is for, who it's for, and when to read it
kept-current-by: AGENTS.md rules + tool/check_docs.dart (links, decision ids)
---

# review-tuner design docs

These docs explain **how and why** the skill was built. They aren't loaded
when someone *uses* the skill: the runtime layer is [SKILL.md](../SKILL.md),
[references/](../references/formats.md), and [templates/](../templates/proposals.md).

| Doc | Audience | Purpose | Read it when |
|---|---|---|---|
| [background.md](background.md) | users, new maintainers | Why the skill exists, the pilot story, what the first runs found, what it can and can't prove | You're deciding whether to use it, or explaining it to someone |
| [decisions.md](decisions.md) | maintainers, agents changing the skill | Decision log (D-ids): what was decided, why, and what replaced it; complexity deliberately left out | Before changing behavior, or when something looks odd and you want to know if it's on purpose |
| [lessons.md](lessons.md) | maintainers, agents changing the skill | Things learned the hard way, each with evidence and its consequence | Before designing a new feature or a new kind of check |
| [roadmap.md](roadmap.md) | users, maintainers | Open questions, known gaps, future work | You hit a limitation, or want to pick up the next piece of work |
| [../AGENTS.md](../AGENTS.md) | agents and people changing the skill | How to change things safely and keep these docs current | Before your first edit |

## Reading order

- **Using the skill:** [SKILL.md](../SKILL.md), then [background.md](background.md)
  if you want the motivation.
- **Changing the skill:** [../AGENTS.md](../AGENTS.md), [decisions.md](decisions.md),
  [lessons.md](lessons.md), then the [roadmap](roadmap.md) for what's
  already planned.

## Conventions

- Every doc starts with front matter: `audience`, `purpose`, `kept-current-by`.
- Decisions are `### D<n>: <title>` with a `Status:` line (`accepted`,
  `superseded by D<m>`, or `withdrawn`). Ids are never reused or renumbered.
- No personal data: reviewers are "a maintainer" or "an external contributor";
  public PR numbers and repo names are fine. Data paths are written as `<dataDir>`.
