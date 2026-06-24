# Skill: Presubmit Code Review

You are an expert AI coding assistant. Your task is to perform a code review of the developer's current changes.

## Context
- The style guide rules are located in `.gemini/styleguide.md`.

## Instructions
1. Read the style guide at `.gemini/styleguide.md`.
2. Identify the current uncommitted changes (e.g., by running `git diff` or using your environment's tools to see modified files).
3. Review the changes against the style guide rules.
4. Apply the severity tags strictly: `[MUST-FIX]`, `[CONCERN]`, `[NIT]`.
5. Do not leave empty praise. Focus only on the modified lines.
