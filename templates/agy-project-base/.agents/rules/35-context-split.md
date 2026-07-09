# Context Split Rule

This workspace is executed by Antigravity. ChatGPT companion may prepare prompts, audits and plans, but companion text is not workspace evidence.

## Source of truth for this workspace

- `.agy/PHASE_STATUS.json`
- `.agy/AGENT_STATE.md`
- `.agents/AGENTS.md`
- project docs
- deterministic command output
- git diff/status
- artifacts with path/size/hash

## Rule

Do not assume a ChatGPT companion update changes this workspace.
Do not assume public pipeline docs mean this project has migrated.
Do not migrate pipeline/runtime files during active feature implementation.

If pipeline migration is requested while feature work is active, stop and recommend `/auditphase` followed by `/planonly` migration planning.
