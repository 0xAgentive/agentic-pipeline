---
description: Implement exactly one approved phase, verify it and stop.
---

# /nextphase

## Preconditions

- read `.agy/PHASE_STATUS.json`;
- the requested work must match `next_required_command`;
- inspect git status before editing;
- stop if unrelated dirty changes make scope unsafe.

## Execution

1. Implement exactly one approved phase.
2. Stay inside the phase allowlist.
3. Do not silently expand requirements.
4. Run deterministic checks required by the phase.
5. Produce required screenshots/reports/artifacts where applicable.
6. Update `.agy/PHASE_STATUS.json`, `.agy/AGENT_STATE.md`, `.agy/RECOVERY_PROMPT.md` and evidence pointers.
7. Report changed files, checks, artifacts, remaining risks and exact next command.

## Forbidden

- phase jumping;
- model-only verification;
- broad unrelated refactors;
- automatic push/publish;
- declaring SHIP.

Stop after one phase.
