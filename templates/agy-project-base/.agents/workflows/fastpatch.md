---
description: FLOW-mode script-gated patch for very small low-risk UI/style changes.
---

# /fastpatch

Use only for one small low-risk product change.

## Preconditions

- active owner-approved FLOW work item;
- no privacy, data-integrity, security, health-adjacent, migration or release risk;
- `scripts/Test-FastPatchAllowed.ps1` passes.

## Flow

1. Run the preflight gate.
2. Create exact execution scope.
3. Make only the requested edit.
4. Run the mandatory post-edit gate with `-RequireChanges`.
5. Run one targeted cheap check.
6. Write or update `.agy/RUN_RESULT.json`.
7. Stop with the product result.

No independent audit by default.
No evidence archive unless the artifact itself is the deliverable.
No plan approval request.
No hashes in the owner-facing response.
