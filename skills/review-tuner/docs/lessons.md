---
audience: maintainers and agents changing the skill
purpose: things learned the hard way while piloting, testing, and reviewing the skill - each with its evidence and its consequence for the design
kept-current-by: AGENTS.md rules + tool/check_docs.dart (links, decision ids)
---

# Lessons

Each entry: what we learned, the evidence, and what changed because of it.
Add new entries at the end of the right section; don't rewrite old evidence.

## Replays and simulators

**Models differ a lot in how much of the bot they reproduce.**
On P0-1, under the old rule, the Pro-class primary flagged allowed paths in
13/18 runs (per run, 0/7 to 5/7 of the bot's real comment locations), while
Flash and Claude flagged 6/6 each and the bot itself flagged all 3 motivating
PRs. Yet on a later doc-scope check, Pro reproduced the bot's "public-quality
docs" demand almost verbatim where Flash produced nothing.
→ No pinned primary model (D34); which model best simulates the bot is an
open question ([roadmap.md](roadmap.md)). Three runs is the minimum for
`evaluate` because a single run can show nothing.

**Simulators often don't reproduce the bot's false claims from a diff alone.**
On 2 of 3 "stop the bot's false claims" checks, Flash never made the bot's
mistakes under either guide; a Pro probe also showed nothing on false
compile-error claims. Those claims likely depend on repo context.
→ "No signal" is inconclusive, not evidence against. Rules that stop false
claims need a Pro probe or `evaluate` (checkouts) before a PR.

**Adding missing knowledge is the easiest win to show.**
The clearest quick-check results taught the bot something humans keep asking
for: a repo redirect (2/6 → 6/6) and shared-helper names (4/6 → 6/6).
→ Expect quick checks to be most useful for `add` suggestions.

**A quick check finds wording problems before a PR.**
A release-note rule hurt (6/6 → 5/6) because it was stricter than what
maintainers merge. Narrowed and re-checked with 3 runs: 15/18 → 18/18.
→ `check` is cheap enough to run on every suggestion; `--runs` (D45).

**Fidelity can't tell faithful from trigger-happy when the bot flagged everything.**
On P0-1's motivating PRs the bot flagged every in-scope file, so a reviewer
that flags everything scores 100%.
→ Fidelity is reported as recall only (D35); a better fidelity set is roadmap work.

**Run-to-run variance is large.**
One negative PR alone swung noise by ±0.5 per run in P0-1.
→ The noise Reject cut-off sits at +1.0 (D38).

## Evidence from review history

**Most pushback against the bot comes from PR authors.**
In one repo, 80 of 85 human replies to the bot came from PR authors. The old
rule (ignore authors' comments) scored "the bot is wrong" themes at zero.
→ Authors' rebuttals count at half weight (D41). In the recount, one theme
went from 0 to 3.75 weighted evidence, and themes that had been hidden surfaced.

**Replies aren't rebuttals, and regexes can't tell them apart.**
Most replies to the bot are "Done" or "Good catch". A regex classifier found
only ~10–30% of hand-counted rebuttals: maintainers rebut by stating facts,
not with pushback words.
→ The agent classifies, the script counts (D42); counter-evidence caps (D44).

**Acknowledgments are most bot replies in small repos, few in big ones.**
A narrow acknowledgment filter dropped 29 of 79 replied-to bot threads in
one repo and 17 of 44 in another, but only 15 of 177 in `flutter/flutter`,
where replies explain themselves. Its first version also dropped replies
written as `> [!NOTE]` callouts, since it stripped quoted lines.
→ `--no-acks` (D58) shrinks small repos' views by about a third; for big
repos the win comes from the views themselves and paging (D57). Quoted lines
are kept when the whole reply is quoted.

**A check verdict can hinge on one regex match.**
A gating check looked "mixed" because the baseline's only hit matched a
feature-flag name, not the concern. After tightening the regex: 6/18 → 15/18.
→ Every flagged run lists its matched comment; read them before reporting (D40).

**Automation accounts pollute roles in unconfigured repos.**
In `flutter/flutter`, an auto-roller account counted as 160 maintainer PRs.
Marking an agent account (named after a person) as a bot would also drop the
human reviews of its PRs.
→ Default automation patterns (D55) and a separate agent-account list (D56).
On the same 14-day window the defaults matched the hand-written config
exactly (402 PRs, 182 excluded, same 47 maintainer reviewers). A
`(^|[-_])bot$` pattern alone missed two accounts (`fluttergithubbot`,
`flutteractionsbot`) that end in `bot` with no separator; a bare `bot$` would
also catch human names, so the defaults add `(github|actions)-?bot$` instead.

**GitHub search caps at 1000 results.**
Busy repos hit it within weeks (`flutter/flutter` used a 14-day window).
→ `collect.dart` fails loudly and asks for a shorter window instead of
silently truncating.

## Mechanics

**The diff base must be the PR's base, not the default branch.**
Pilot repos squash-merge, so diffing against `main` worked. In merge-commit
repos the reviewed commit is already in `main` and the diff comes out empty.
→ D46.

**File access must be granted before subagents start.**
In the pilot, a batch of 24 runs hit permission denials and was discarded;
subagents already waiting at a prompt don't pick up a rule added later.
→ SKILL.md step 1 asks for data-dir access up front.

**Workers should write their own results.**
The pilot needed two scripts to scrape results out of agent transcripts, and
they only worked on one agent.
→ D31. A `read_file` result can't be parsed as JSON inside a scripted
workflow, so orchestrators that batch may want a ready-made dispatch list
([roadmap.md](roadmap.md)).

**The orchestrator gets unblinded.**
A reviewer's output quoted the candidate's wording, revealing the arms.
→ Blind the workers, not the orchestrator, and keep scoring deterministic (D32).

**The bot probably doesn't follow links.**
In `flutter/devtools`, the style guide linked `STYLE.md` and `AGENTS.md`
relative to the wrong directory, and most rules lived behind those links.
→ The audit resolves links and flags link-only rules (D51).

**Sequential content fetches can hang; code search lies by omission.**
One audit spent ~40 minutes on sequential fetches, and code search reported
existing symbols as missing.
→ Empty code search is inconclusive (D51); the audit reads a shallow clone
(D54). The likely cause of the hang is the next entry.

**Slow runs were retries of a rate limit that couldn't clear.**
In a sandboxed shell `gh` had no valid token, so requests went out
unauthenticated from a shared IP and got "API rate limit exceeded" (HTTP 403).
`gh()` treated any "rate limit" as transient and retried 4 times (5 + 20 + 45 +
80 s), so every call took ~150 s and then failed: a 6-PR collection that takes
~3 s outside the sandbox spent 2.5 minutes on the listing query alone, and
sequential per-file fetches add up to tens of minutes.
→ D53: the primary rate limit fails at once, with a hint to check
`gh auth status`; SKILL.md says to rerun outside the sandbox.

**A judge without the style guide calls guide-mandated nits noise.**
In P0-1 the judge rated style-guide-mandated nits as noise, in both arms alike.
→ Noise is compared between arms, not read in absolute terms; the rubric notes the bias.

## Code

**Fully typed code costs lines.**
Moving to one typed corpus model, enums, and records removed duplicated logic
but added declarations; with new validation, `score.dart` grew from ~880 to
~1,380 lines while dead code was being removed.
→ Accepted for correctness (D36). Prefer deleting features over adding types
for them.

**Reviewers who don't run the analyzer report false lint errors.**
Two independent code reviews both flagged a "must-fix" lint the analyzer
didn't report.
→ Run `dart analyze` before trusting a style finding.
