# 🚧 Agent Skills (WIP)

A collection of custom skills for agentic workflows.

(Limited to Gemini / Antigravity for now.) 

## Skills Included

### 📊 Estimate Conversation Tokens
Analyzes the full conversation transcript logs (`transcript_full.jsonl`) for the **current active conversation** (automatically resolved via environment variables) to estimate character lengths, model invocations (turns), cumulative input/output tokens, and context caching savings.

---

## 📊 Example Run Output

When the skill is executed, it outputs a detailed step-by-step breakdown grouped by each user request, followed by cumulative calculations:

### Turn-by-Turn Granular Cost Breakdown

| Turn | User Request / Task | Model Calls | Est. New Input Chars | Est. New Output Chars | Cumulative Tokens (No Cache) | Cumulative (With Cache) |
|---|---|---|---|---|---|---|
| #1 | `I'd like to understand token use when I'm using...` | 9 | 4,756 | 19,265 | 109,545 | 27,386 |
| #2 | `I'd like visual feedback. So for example, for m...` | 19 | 1,048 | 100,256 | 404,338 | 101,085 |
| #3 | `Could you rewrite the estimate_tokens script in...` | 8 | 1,209 | 21,922 | 574,324 | 143,581 |
| ... | *[Truncated for readability]* | ... | ... | ... | ... | ... |
| #21 | `This is great for tracking the accumulating cos...` | 2 | 1,128 | 11,064 | 5,734,221 | 1,433,555 |

### 📈 Total Aggregated Calculations

* **Total Model Invocations (Turns):** 159
* **Total Estimated Input Tokens:** 4,101,564
* **Total Estimated Output Tokens:** 42,657
* **Total System & Tool Definition Overhead:** 1,590,000
* **Grand Total (Without Caching):** **5,734,221**
* **Grand Total (With Context Caching active):** **~1,433,555**

---

## 🚀 Installation

### Option 1: Global Setup (Available everywhere)
Clone the repository and symlink the skill to your global config directory:
```bash
git clone https://github.com/pq/pq-agent-skills.git ~/src/pq-agent-skills
mkdir -p ~/.gemini/config/skills
ln -s ~/src/pq-agent-skills/skills/estimate-conversation-tokens ~/.gemini/config/skills/estimate-conversation-tokens
```

### Option 2: Workspace Integration (Project-specific)
Add this repository to your project's `.agents/skills.json` under your `entries` paths:
```json
{
  "entries": [
    { "path": "<path-to-checkout>/pq-agent-skills/skills" }
  ]
}
```
*Note: Make sure to replace `<path-to-checkout>` with the absolute local path to your checkout.*

---

## 🛠️ Usage / Invocation

Once the skill is installed, you can invoke it in your agent chat interface in two ways:

1. **Via Slash Command:**
   Type the slash command directly in the chat:
   ```text
   /estimate-conversation-tokens
   ```

2. **Via Natural Language:**
   Ask the agent directly:
   > *"Estimate token usage for this conversation."*
