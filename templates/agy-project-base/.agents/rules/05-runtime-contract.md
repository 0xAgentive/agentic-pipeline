# Runtime Contract

This workspace is operated through the Agentic Development Pipeline.

## Source of truth

Before any substantial action, read:

- `.agy/PHASE_STATUS.json`
- `.agy/AGENT_STATE.md`
- `.agy/RECOVERY_PROMPT.md`

The field `next_required_command` defines the expected next workflow.

## State discipline

Do not silently jump phases.

If the user asks for work that does not match the current state, respond with:

```text
STATE CHECK
Current expected command: <value from .agy/PHASE_STATUS.json>
User requested: <requested action>
Recommended next command: <safe next command>
Reason: <short reason>
```

Do not execute implementation work from a planning, audit, landing, or shipcheck state.

## Phase separation

- `/specdoc` writes specifications only.
- `/planonly` writes plans only.
- `/auditphase` verifies state, docs, checks, and risks only.
- `/probephase` validates local assumptions only.
- `/nextphase` implements one approved phase only.
- `/fastpatch` is allowed only if `scripts/Test-FastPatchAllowed.ps1` exits with code 0.
- `/githubprepare` prepares repository metadata only.
- `/githubsync` publishes through deterministic `git` and `gh` commands only.
- `/landing` saves recoverable state only.
- `/shipcheck` decides release readiness only.

## Verification rule

Model-written reports are not verification.

Verification means deterministic evidence:

- exit code 0 from checks;
- git diff reviewed;
- screenshots or browser artifacts for UI;
- security/privacy grep or tests when relevant;
- semantic/domain tests for critical logic.

## Override rule

A human may explicitly override the recommended next command, but the agent must record the override and residual risk in `.agy/EVIDENCE_LOG.md`.
