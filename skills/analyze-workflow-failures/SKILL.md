---
name: analyze-workflow-failures
description: Analyze GitHub Actions workflow failures for one or more repositories, including success rates and summaries of error logs.
---

# Skill: Analyze Workflow Failures

You are an agent assisting the user with understanding the stability of their CI/CD pipelines.

## Step-by-Step Execution
1. Identify all active workspaces in the user's environment. For each workspace, use the command `git remote get-url upstream || git remote get-url origin` to discover its tentative GitHub repository name (e.g. `flutter/flutter-intellij`).
2. Use your `ask_question` tool to ask the user to configure the analysis parameters. You should ask three questions in a single tool call, in this exact order:
   - Question 1 (Repositories): "Which repositories would you like to analyze?"
     - Set `is_multi_select: true`.
     - Option 1 must be: "All repos in this workspace: <repo1>, <repo2>, ..." (listing out the tentative repos you found).
     - Subsequent options should list each repository individually (e.g., "<repo1>", "<repo2>").
   - Question 2 (Remote): "Which remote should be used to resolve the repositories?"
     - Options: "(Default) upstream", "origin"
     - Set `is_multi_select: false`
   - Question 3 (Time Interval): "What time interval (in days) should be analyzed?"
     - Options: "(Default) 7", "14", "30"
     - Set `is_multi_select: false`
3. Wait for the user to submit their choices. Extract the list of selected repositories, the remote, and the time interval.
4. If the user selected a different remote than the default (e.g., `origin` instead of `upstream`), re-evaluate the repository names by running `git remote get-url <selected_remote>` in the workspaces to get the exact repository names the user intended.
5. Run the `analyze.dart` script provided in this skill's `scripts/` directory (you can determine the absolute path by replacing `SKILL.md` with `scripts/analyze.dart` in the path of this file), passing all final resolved repositories as arguments and the selected time interval.
   Command: `dart <absolute_path_to_analyze_dart> <repo1> <repo2> ... --days=<selected_interval>`
7. Wait for the script to finish running via the `manage_task` or `schedule` workflow. It will fetch logs via `gh` CLI.
8. The script will output a complete markdown report after the `--- REPORT START ---` marker.
9. Extract the markdown report and save it to the agent's artifact directory as a markdown file, setting the `ArtifactMetadata` property.
10. Present the key findings to the user, summarizing each repository, and link to the generated artifact so they can investigate the failures further (the report includes clickable URLs to each GitHub Actions run).
