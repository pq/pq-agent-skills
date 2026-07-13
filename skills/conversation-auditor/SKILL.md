---
name: conversation-auditor
description: Introspects conversation history to suggest new tools, skills, MCP servers, or identify context window hogs and optimization opportunities.
---

# Conversation Auditor

## Overview
This skill audits previous conversation transcripts to help the user identify ways to tune their agentic coding experience. It looks for commonly performed actions, repetitive low-level commands, tool sequences that can be aggregated, and places where the context window is being heavily utilized.

## When to use
Trigger this skill when the user asks to "audit my conversation", "suggest new skills", "find MCP server opportunities", or "introspect conversation history".

## Workflow

1. **Ask for Target (if not specified):** Ask the user if they want to audit their *most recent* conversation, or a specific conversation ID. (You can check their recent conversation history in your `<conversation_summaries>` block for candidates).
2. **Run the Audit Script:** 
   Execute the provided Dart script against the target conversation ID:
   ```bash
   # Assuming the agent is running in a standard setup, you can locate the script relative to this skill file.
   # Alternatively, if you know the path to this skill directory:
   dart run <path_to_this_skill_directory>/scripts/audit_conversation.dart <conversation_id> <path_to_app_data_dir>
   ```
3. **Analyze the Output:** 
   Read the output of the script. The script will highlight:
   - Tool Usage Frequencies
   - Repeated Tool Sequences
   - Raw Shell Commands Executed
   - Largest Context Hogs
4. **Generate Recommendations:**
   Use your own intelligence (as an LLM) to interpret the script's output and present a structured markdown report to the user in an Artifact (e.g. `audit_report.md`).
   Your report should include:
   - **Potential Scripts/Aliases:** Are there bash commands being run over and over that could be a script?
   - **New Skills:** Are there long sequences of tools (like viewing a file, searching, replacing) that follow a specific pattern? Suggest creating a skill for it.
   - **MCP Server Opportunities:** Are there low-level tools (like grep, find, API curl requests) being used that could be wrapped in a more structured MCP server for reliability?
   - **Context Window Analysis:** Identify steps that consumed large amounts of tokens and suggest how the user (or the agent) might avoid this in the future (e.g., using `grep_search` instead of reading an entire file).

5. **Deliver Findings:** Provide the report to the user, highlighting the highest-value optimization opportunities.
