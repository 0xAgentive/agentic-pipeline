# Work-Item Scope and Bounded Repair Convergence

FLOW/GUARDED daily work uses:

- `WORK_ITEM.json` — immutable owner authorization;
- `EXECUTION_SCOPE.json` — exact live paths;
- `EXECUTION_LEASE.json` — pre-write authority;
- `AUDIT_COVERAGE_MATRIX.json` — complete first-audit coverage;
- `FINDINGS.json` and `REPAIR_DELTA.json` — stable repair lifecycle;
- `RUN_RESULT.json` and `CLOSURE_STATE.json` — final authority.

## Default repair budget

- FLOW: at most two grouped repair batches;
- GUARDED: one comprehensive audit, at most three grouped repair batches, one final audit;
- RELEASE: release-specific policy, never weaker than GUARDED.

A batch may resolve multiple related findings. Do not count individual edits as separate cycles.

After the budget is exhausted:

- open product blockers → one material hard stop;
- only verification/audit limitations → `completed_with_verification_debt`, release blocked, next owner goal allowed;
- no open material findings → accepted closure.

A new material finding after the comprehensive audit is `AUDIT_COVERAGE_MISS`. It must be recorded in Pipeline evals and must not silently reset the budget.
