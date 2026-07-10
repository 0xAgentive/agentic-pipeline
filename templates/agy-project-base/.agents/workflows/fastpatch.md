---
description: Script-gated fastpatch for very small UI/style changes only. The final gate must run after edits.
---

# /fastpatch

Use only for a very small, low-risk UI or styling change.

## Forbidden scope

Do not use this workflow for backend, analytics, ingestion, data models, reports, exports, storage, security, hooks, workflows, templates, MCP configuration, package/dependency changes, or release readiness.

## Required flow

1. Read `.agy/PHASE_STATUS.json`.
2. Run the preflight gate:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FastPatchAllowed.ps1

3. If preflight fails, stop and use `/auditphase` or `/nextphase`.
4. Make only the requested small edit.
5. Run the mandatory post-edit gate:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FastPatchAllowed.ps1 -RequireChanges

6. Run one targeted cheap check if available.
7. Append one evidence-lite entry only if `.agy/EVIDENCE_LOG.md` exists.
8. Stop.

## Completion rule

A clean preflight with no changed files is not authorization for completion. Success requires a passing post-edit gate with `-RequireChanges`.
