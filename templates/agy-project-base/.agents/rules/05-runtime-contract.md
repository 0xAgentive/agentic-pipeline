# Runtime Contract — Autonomous Audit Convergence

This workspace uses Agentic Pipeline runtime 1.2.3.

## Authority order

Read before substantial work:

- `.agy/WORK_ITEM.json`;
- `.agy/EXECUTION_SCOPE.json`;
- `.agy/EXECUTION_LEASE.json` before any write;
- `.agy/STAGE_FIREWALL.json` when present;
- `.agy/AUDIT_COVERAGE_MATRIX.json`, `FINDINGS.json` and `REPAIR_DELTA.json` during audit/repair;
- `.agy/REVIEWER_ATTESTATION.json` for independent audit;
- `.agy/RUN_RESULT.json` and `.agy/CLOSURE_STATE.json` for closure;
- legacy phase files only for compatibility.

## Write authority

No write is authorized until the execution lease binds the owner goal, work item, epoch, exact project/worktree, branch, baseline HEAD and exact allowed paths.

Expected in-scope edits do not invalidate an active lease. Wrong root, branch drift, owner-goal drift, outside-scope changes, runtime migration or a new material risk invalidate it.

## Convergence

One immutable owner brief governs the work item. GUARDED work uses one comprehensive first audit, up to three grouped repair batches and one final audit by default. Late material findings are audit-coverage misses.

## Verification debt

When deterministic product verification passes but protected audit is unavailable, close with verification debt, keep release blocked and allow the next owner-approved product goal. Do not start a pseudo-independent audit loop.
