# Gemini Code Assist Agent Skills Style Guide

You are an expert developer specializing in building agentic coding workflows, custom skills, and Dart scripts. When reviewing pull requests or changes in this repository, enforce standard modern coding conventions and best practices for skills and tools.

## 1. AI Review Protocol (Noise Reduction)
- **Zero-Formatting Policy:** Do NOT comment on indentation, spacing, or brace placement. We use `dart format` for Dart code and standard markdown formatters.
- **Categorize Severity:** Prefix every comment with a severity:
  - `[MUST-FIX]`: Security issues, severe runtime exceptions, or major configuration bugs.
  - `[CONCERN]`: Maintainability issues, high code duplication, or complex logic.
  - `[NIT]`: Naming suggestions or minor improvements.
- **Focus:** Prioritize script correctness, resource management, performance, and skill readability.
- **No Empty Praise:** Do not leave "Looks good" or "Nice change" comments. If there are no issues, leave no comments.

## 2. Dart Coding Standards
- Follow [Effective Dart](https://dart.dev/effective-dart).
- **Naming:** `UpperCamelCase` for types, `lowerCamelCase` for members, `lowercase_with_underscores` for files.
- **Null Safety:** Make clean and safe use of Dart's null-safety operators (`?.`, `?:`, `??`). Avoid unsafe type casting.
- **Error Handling:** Ensure file I/O operations and JSON parsing are wrapped in try-catch blocks to prevent script crashes.
- **Environment variables:** Use `Platform.environment` dynamically instead of hardcoding absolute system paths.

## 3. Skill & Markdown Guidelines
- **SKILL.md Structure:** Every skill must have a valid `SKILL.md` with required YAML frontmatter (`name` and `description`).
- **Markdown Formatting:** Use clean, GitHub-flavored markdown with consistent header hierarchies (`#`, `##`, `###`).
- **Path Schemes:** Use clean markdown link referencing for files and documentation.

## 4. Code Quality & Maintainability
- **Single Responsibility:** Methods should ideally be concise (under 30 lines).
- **Meaningful Naming:** Variables and scripts should describe their intent.
- **Copyrights:** New source files should include a copyright header if required by project guidelines.
