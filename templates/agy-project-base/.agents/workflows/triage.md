---
description: Read-only JSON classifier that recommends the next safe workflow.
---

# /triage

Do not edit files.
Do not implement.
Do not commit.
Do not mark ready.
Do not run broad tests.

Read only enough state to recommend the next command:

- `.agy/PHASE_STATUS.json`
- `.agy/PRODUCT_CONTRACT.json` if present
- `.agy/REQUIREMENTS_DELTA.ndjson` if present
- `git status --short`

Output JSON only:

```json
{
  "recommended_command": "/auditphase",
  "risk_level": "low|medium|high|critical",
  "reason": "",
  "required_reads": [],
  "forbidden_reads_by_default": ["docs/AGENTIC_PIPELINE_PLAYBOOK.md"],
  "tool_profile": "local-readonly",
  "requires_human_approval": false
}
```

Stop after JSON.
