# AGENTS.md

## For agents and contributors

Run the checks before sending a change:

```bash
dart pub get
dart format .
dart analyze --fatal-infos
dart tool/check_docs.dart            # add --skill <name> or --base <ref>
```

CI (`.github/workflows/checks.yaml`) runs the same commands on every pull
request; it checks formatting with
`dart format --output=none --set-exit-if-changed .`.

`tool/check_docs.dart` enforces these conventions:

- **Skills.** Each skill lives in `skills/<name>/` with a `SKILL.md` whose YAML
  front matter has `name` (equal to the directory name) and a non-empty
  `description`. `README.md` mentions `skills/<name>` for every skill.
- **Design docs (optional).** A skill may keep design docs in
  `skills/<name>/docs/*.md` and agent notes in `skills/<name>/AGENTS.md`. Each
  of those files starts with front matter with non-empty `audience:`,
  `purpose:`, and `kept-current-by:` fields.
- **Decision log.** If `skills/<name>/docs/decisions.md` exists, each decision
  is a heading `## D<n>` to `#### D<n>` (for example
  `### D31: Agent-classified rebuttals`) with a `Status:` line in its section:
  `accepted`, `superseded by D<n>`, or `withdrawn`. Every `D<n>` mentioned in
  the skill's markdown (outside code), and every `superseded by` target, must
  be defined.
- **Links.** Relative markdown links in `README.md`, `AGENTS.md`,
  `tool/**/*.md`, and `skills/**/*.md` must resolve (anchors are not checked;
  `http(s)` and `mailto` links, and links in code spans or fenced blocks, are
  ignored).
- **CLI drift (opt-in).** If `skills/<name>/references/formats.md` exists,
  every long option printed by `dart skills/<name>/scripts/<script>.dart --help`
  must appear in `formats.md`, and every `--option` in backticks in
  `formats.md` must be accepted by some script. `--help` must exit 0.
- **Freshness (warning).** When a skill with a `docs/` directory changes
  `scripts/` or `SKILL.md` relative to the base ref (default `origin/main`)
  without touching `docs/`, the check prints a warning. Update the decisions,
  lessons, or roadmap docs, or say in the PR why no update is needed.
- **Privacy (local, opt-in).** If a `.docs-denylist` file exists at the repo
  root (one term per line, `#` for comments), the check fails when any term
  appears as a whole word (case-insensitive) in the checked markdown. The file
  is gitignored; never commit it.
