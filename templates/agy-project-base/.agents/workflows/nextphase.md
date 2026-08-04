---
description: Execute one owner-approved work item through bounded implementation, grouped repair and closure.
---

# /nextphase

## Authority

Read `WORK_ITEM.json`, `EXECUTION_SCOPE.json`, `EXECUTION_LEASE.json`, `STAGE_FIREWALL.json` when present, live Git facts and command inventory.

If no active work item exists, create one from the explicit owner goal. Do not ask for plan approval.

## Before first write

1. Perform read-only discovery.
2. Publish exact `EXECUTION_SCOPE.json`.
3. Issue `EXECUTION_LEASE.json`.
4. Run `Test-ExecutionLease.ps1 -BeforeWrite -MarkWriteStarted`.
5. For scientific work, publish and validate `STAGE_FIREWALL.json`.

No edit is allowed before these gates pass.

## Execution

1. Implement only the immutable owner brief.
2. Run assurance-appropriate deterministic verification.
3. For GUARDED, run one comprehensive `/auditphase` before repair.
4. Repair stable findings through `REPAIR_DELTA.json`, grouped within the convergence budget.
5. Run one final audit when protected reviewer capability exists.
6. Compile `RUN_RESULT.json` and `CLOSURE_STATE.json` from receipts.
7. Stop on accepted closure, verification-debt closure or a material hard stop.

Do not regenerate the owner brief. Do not continue to publication.
