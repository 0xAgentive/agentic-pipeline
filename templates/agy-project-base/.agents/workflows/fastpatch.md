---
description: Script-gated fastpatch for very small UI/style changes only. The final gate must run after edits.
---

# /fastpatch

Do not use this workflow for backend, data, security, reports, exports, storage, hooks, templates, MCP config, package/dependency changes, or release readiness.

## Required flow

1. Read `.agy/PHASE_STATUS.json`.
2. Run the clean-start preflight gate:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FastPatchAllowed.ps1

3. Make only the requested small UI/style edit.
4. Run the mandatory post-edit gate before reporting success:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FastPatchAllowed.ps1 -RequireChanges

5. Run one targeted cheap check if available.
6. Append one evidence-lite entry only if `.agy/EVIDENCE_LOG.md` exists.
7. Stop.

## Important rule

A clean preflight with no changed files is not authorization for completion. The post-edit gate with `-RequireChanges` is mandatory.

## Failure

If the gate fails, stop immediately. The next command must be `/auditphase` or `/nextphase`.
