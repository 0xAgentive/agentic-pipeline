# Runtime Agent Instructions

Framework Runtime Version: `1.2.2`
Primary runtime: Google Antigravity
Hook mode by default: manual guard scripts

This file is the canonical runtime instruction surface for the project. Root `AGENTS.md` is only a pointer.

## Start with current authority

Before substantial work read:

- `.agy/FLOW_POLICY.json` when present;
- `.agy/WORK_ITEM.json` when present;
- `.agy/EXECUTION_SCOPE.json` when present;
- `.agy/RUN_RESULT.json` when present;
- `.agy/RUNTIME_HANDSHAKE.json` when present;
- legacy `.agy/PHASE_STATUS.json`, `.agy/AGENT_STATE.md` and `.agy/RECOVERY_PROMPT.md` for compatibility;
- the selected workflow under `.agents/workflows/`.

A shadow candidate route is diagnostic only. It does not authorize writes.

## Work-item terminality

`SHIP` closes one work item. It does not close the project.
A new explicit owner goal opens a new work item and may route to `/nextphase`.
Only an explicit archived project state closes future product work.

## Assurance modes

- FLOW: ordinary product work; targeted verification; compact result.
- GUARDED: privacy, exports, data integrity, security, health-adjacent or packaged behavior; protected audit.
- RELEASE: publication, migration, distributable identity and release provenance.

Do not escalate to RELEASE because a ZIP exists or internal metadata changed.

## Command discipline

- `/specdoc`: specification only.
- `/planonly`: legacy planning only when objectively routed.
- `/nextphase`: execute one owner-approved work item through implementation, current-scope repair and required audit.
- `/fixcritical`: repair confirmed current-scope product blockers without another owner approval.
- `/auditphase`: read-only verification or protected audit.
- `/fastpatch`: small low-risk FLOW change after deterministic pre/post gates.
- `/probephase`: bounded uncertainty reduction.
- `/visualqa`, `/reportqa`, `/securityaudit`, `/artifactaudit`: evidence gates when applicable.
- `/shipcheck`: RELEASE decision only.
- `/landing`: legacy recovery/orientation only.
- `/githubprepare`, `/githubsync`: release/publication only and never in degraded product execution.

## Scope and repair

Antigravity performs read-only discovery and writes exact `.agy/EXECUTION_SCOPE.json` before the first edit. Do not rely on guessed paths from a remote brief.

Continue current-scope repair automatically while each iteration makes measurable progress. Ask the owner only for scope expansion, destructive/publication action, unavailable required capability, material-risk acceptance, framework migration or repeated no-progress failure.

## Evidence

Model prose is not verification. Use deterministic commands, exit codes, diffs, tests and actual product artifacts.

- FLOW normally uses `WORK_ITEM.json` and `RUN_RESULT.json`.
- GUARDED adds one independent audit result.
- RELEASE may require manifests, provenance and hashes.

Do not print sizes or hashes to the owner unless requested, unresolved corruption exists or release identity depends on them.

## Tools and hooks

Use the smallest tool surface. No write-capable MCP tools without explicit approval.

Hook scripts are manual guards unless `.agents/hooks.json` is non-empty and a local same-surface probe has passed. Do not claim active hooks when configuration is empty.

Project-specific rules and skills may extend this runtime but cannot weaken safety, scope, verification or release boundaries.
