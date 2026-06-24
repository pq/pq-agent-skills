# Agent Skills by PQ (`pq-agent-skills`)

A collection of custom skills for agentic workflows in the Gemini / Antigravity editor space.

## Skills Included

### 📊 Estimate Conversation Tokens
Analyzes the full conversation transcript logs (`transcript_full.jsonl`) to estimate character lengths, model invocations (turns), cumulative input/output tokens, and context caching savings.

---

## 📊 Example Run Output

When the skill is executed, it outputs a detailed step-by-step breakdown followed by cumulative calculations:

```markdown
### Turn-by-Turn Content Breakdown

| Step | Source | Type | Content Size (Chars) | Role | Est. Tokens (4 chars/token) |
|---|---|---|---|---|---|
| 0 | USER_EXPLICIT | USER_INPUT | 1,334 | Input (to Agent) | 334 |
| 1 | SYSTEM | CONVERSATION_HISTORY | 0 | Input (to Agent) | 0 |
| 2 | SYSTEM | KNOWLEDGE_ARTIFACTS | 3,422 | Input (to Agent) | 856 |
| 4 | MODEL | PLANNER_RESPONSE | 2,587 | Output (from Agent) | 647 |
| 5 | MODEL | LIST_DIRECTORY | 222 | Output (from Agent) | 56 |
| 7 | SYSTEM | EPHEMERAL_MESSAGE | 0 | Input (to Agent) | 0 |
| 8 | MODEL | PLANNER_RESPONSE | 486 | Output (from Agent) | 122 |
| 9 | MODEL | GENERIC | 7,025 | Output (from Agent) | 1,756 |
| 11 | MODEL | PLANNER_RESPONSE | 611 | Output (from Agent) | 153 |
| 12 | MODEL | SEARCH_WEB | 223 | Output (from Agent) | 56 |
| 14 | MODEL | PLANNER_RESPONSE | 464 | Output (from Agent) | 116 |
| 15 | MODEL | SEARCH_WEB | 238 | Output (from Agent) | 60 |
| 17 | MODEL | PLANNER_RESPONSE | 7,409 | Output (from Agent) | 1,852 |

### Cumulative Token Calculations

Because the agent runs in a loop, each time the agent invokes the model (PLANNER_RESPONSE), it sends the *entire accumulated history* up to that point.

* **Number of Model Invocations (Turns):** 49
* **Estimated Cumulative Input Tokens (Transcript):** 403,788
* **Estimated Output Tokens (Reasoning & Tool Calls):** 15,532
* **Estimated System & Tool Definition Overhead (10,000/turn):** 490,000
* **Grand Total Estimated Tokens (without Caching):** **909,320**
* **Grand Total Estimated Tokens (with Context Caching active):** **~227,330**
```

---

## 🚀 Installation

### Option 1: Global Setup (Available everywhere)
Clone the repository and symlink the skill to your global config directory:
```bash
git clone https://github.com/pquitslund/pq-agent-skills.git ~/src/pq-agent-skills
mkdir -p ~/.gemini/config/skills
ln -s ~/src/pq-agent-skills/skills/estimate-conversation-tokens ~/.gemini/config/skills/estimate-conversation-tokens
```

### Option 2: Workspace Integration (Project-specific)
Add this repository to your project's `.agents/skills.json` under your `entries` paths:
```json
{
  "entries": [
    { "path": "/Users/pquitslund/src/repos/pq-agent-skills/skills" }
  ]
}
```
*Note: Make sure to replace the path with your absolute local path.*
