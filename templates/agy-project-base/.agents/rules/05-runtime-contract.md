# Runtime Contract — Owner-Autonomous Execution

This workspace uses Agentic Pipeline runtime 1.2.13.

## Authority order

Read before substantial work:

- `.agy/WORK_ITEM.json`;
- `.agy/EXECUTION_SCOPE.json`;
- `.agy/EXECUTION_LEASE.json` before any write;
- `.agy/STAGE_FIREWALL.json` when present;
- `.agy/AUDIT_COVERAGE_MATRIX.json`, `FINDINGS.json` and `REPAIR_DELTA.json` during audit and repair;
- `.agy/PROGRESS_STATE.json` and `.agy/NEXT_ACTION.json` for automatic continuation;
- `.agy/REVIEWER_ATTESTATION.json` for protected review;
- `.agy/RUN_RESULT.json` and `.agy/CLOSURE_STATE.json` for closure;
- legacy phase and repair-count files only as historical compatibility data.

## Write authority

No write is authorized until the exact execution lease binds the owner goal, work item, exact project/worktree, branch, baseline HEAD, stage firewall and exact allowed paths. The project-local PreToolUse hook enforces this before the file change.

## Convergence

One owner-approved goal governs one immutable work item. Audit correction, implementation repair, verification retry, evidence rebuild and control-plane repair continue automatically while material progress is observed. Internal iteration state is diagnostic and never requires owner approval.

Two consecutive equivalent no-progress results may stop the current work item. Ask the owner only for a real decision: changed requirements or scope, a destructive or irreversible action, release/publication, credentials/private data/paid network access, material risk acceptance, a normative protocol change, or a required capability that is genuinely unavailable.

## Verification debt

When deterministic product verification passes but protected review is unavailable, close with verification debt, keep release blocked and allow the next owner-approved product goal. Do not create a pseudo-independent audit loop.
