# Runtime Agent Instructions

Framework Runtime Version: `1.2.0`
Primary runtime: Google Antigravity
Hook mode by default: manual guard scripts

This file is the canonical runtime instruction surface for the project. Root `AGENTS.md` is only a pointer.

## Start with state

Before substantial work read:

- `.agy/PHASE_STATUS.json`
- `.agy/AGENT_STATE.md`
- `.agy/RECOVERY_PROMPT.md`
- the selected workflow under `.agents/workflows/`

`next_required_command` defines the expected next workflow. Do not silently jump phases.

## Command discipline

- `/specdoc`: specification only.
- `/planonly`: plan only.
- `/auditphase`: read-only verification.
- `/probephase`: bounded probe only.
- `/nextphase`: exactly one approved implementation phase.
- `/fastpatch`: only after the post-edit `-RequireChanges` script gate passes.
- `/visualqa`, `/reportqa`, `/securityaudit`, `/artifactaudit`: evidence gates, not feature implementation.
- `/shipcheck`: SHIP/NO-SHIP decision only.
- `/landing`: recovery/orientation only.
- `/phasebatch`: disabled unless explicitly unlocked.

## Evidence policy

Model prose is not verification. Use deterministic commands, exit codes, diffs, tests, logs, screenshots and artifact manifests.

Material work must keep state/evidence pointers consistent. Empty placeholder files are not evidence.

## Product evidence

Before SHIP, verify:

- `.agy/PRODUCT_CONTRACT.json` is configured;
- requirement deltas are resolved;
- required evidence and artifacts exist;
- visual/report/security gates are complete when applicable;
- rollback notes exist.

## Tools and hooks

Use the smallest tool surface. No write-capable MCP tools without explicit approval.

Hook scripts are manual guards unless `.agents/hooks.json` is non-empty and a local Antigravity hook probe has passed. Do not claim active hooks when configuration is empty.

## Project-specific context

Project-specific rules and skills may extend this runtime, but cannot weaken phase, safety, evidence or shipcheck contracts.
