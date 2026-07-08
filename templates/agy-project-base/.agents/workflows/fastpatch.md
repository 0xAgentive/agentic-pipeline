---
description: Execute a tiny UI/styling patch only when the deterministic fastpatch gate approves the current diff.
---

# /fastpatch

Do not use this workflow for backend, data, security, reports, exports, sanitizer, storage, hooks, workflows, MCP config, or dependencies.

## Required gate

Before editing or claiming fastpatch eligibility, run:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FastPatchAllowed.ps1

The gate must exit with code 0.

The gate checks both:

- changed file paths;
- added diff lines for blocked imports, backend coupling, network/storage calls, unsafe DOM APIs, dynamic evaluation, and Node/system APIs.

## If the gate fails

Stop.

Report:

- blocked files or lines;
- required next command: `/auditphase` or `/nextphase`.

Do not continue under `/fastpatch`.

## Allowed work after gate passes

Only:

- make the approved tiny UI/styling edit;
- run a targeted cheap check;
- append one evidence-lite entry if `.agy/EVIDENCE_LOG.md` exists;
- stop.

## Forbidden

- broad scans;
- `/planonly`;
- `/auditphase`;
- `/codebase-map`;
- dependency changes;
- release-readiness claims;
- editing `.agents`, `.agy`, hooks, workflows, templates, MCP config, package files, backend, reports, exports, sanitizer, database/storage, or semantic/domain logic.

## Evidence-lite format

    UTC:
    Command: /fastpatch
    Files:
    Checks:
    Result:
    Risk class: low UI/styling only
    Next:
