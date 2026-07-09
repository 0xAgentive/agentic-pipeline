---
description: Read-only classifier that recommends the next safe pipeline command. No writes.
---

# /triage

Use this workflow when the user asks what to do next, when state is unclear, or when a task may belong to ChatGPT companion rather than Antigravity execution.

## Rules

- Do not edit files.
- Do not implement code.
- Do not run broad tests.
- Do not publish or push.
- Read only state/docs needed for routing.

## Read

- `.agy/PHASE_STATUS.json`
- `.agy/AGENT_STATE.md`
- `.agents/AGENTS.md`
- relevant docs if needed
- git status if needed

## Output

Return:

```json
{
  "recommended_command": "/auditphase",
  "risk_level": "low|medium|high",
  "reason": "...",
  "should_use_chatgpt_companion": true,
  "should_use_antigravity": true,
  "blocked_by": [],
  "next_prompt": "..."
}
```

Stop after the recommendation.
