---
description: Repair confirmed current-scope findings in one bounded grouped batch.
---

# /fixcritical

Continue the current work item. Never create a new semantic brief.

## Inputs

- immutable `WORK_ITEM.json`;
- valid `EXECUTION_LEASE.json`;
- `FINDINGS.json`;
- current `REPAIR_DELTA.json`;
- `REPAIR_BUDGET.json`;
- optional `STAGE_FIREWALL.json`.

## Procedure

1. Validate execution lease and repair budget.
2. Repair only the finding IDs in the current repair delta.
3. Do not expand scope without one material hard stop.
4. Update finding lifecycle: `open_confirmed → fixed_unverified → verified_resolved`.
5. Run only the affected deterministic verification plus required regressions.
6. Register the grouped repair batch once.
7. Return to final audit or closure compiler.

If the budget is exhausted, close with verification debt when only verification/release limitations remain, or issue one product hard stop when product blockers remain.
