# Runtime Contract — Flow Restoration

This workspace is operated through the Agentic Development Pipeline.

## Sources of truth

Read before substantial work:

- `.agy/WORK_ITEM.json` when present;
- `.agy/FLOW_POLICY.json` when present;
- `.agy/EXECUTION_SCOPE.json` when present;
- `.agy/RUN_RESULT.json` when present;
- `.agy/RUNTIME_HANDSHAKE.json` when present;
- legacy `.agy/PHASE_STATUS.json` and phase files for compatibility.

## Terminality

`SHIP` closes one work item. It does not archive the project.
A new explicit owner goal opens a new work item and may route to `/nextphase`.
Only an explicit archived project state closes all product work.

## Assurance modes

- FLOW: ordinary product work and low-risk changes.
- GUARDED: privacy, exports, data integrity, security, health-adjacent or packaged behavior.
- RELEASE: publication, migration and distributable identity.

## Degraded product execution

A stale or schema-invalid legacy phase contract may close release/publication actions without blocking an owner-approved FLOW or GUARDED work item.

In degraded product execution:

- `/nextphase`, `/fixcritical`, `/auditphase` and eligible `/fastpatch` may be used;
- `/shipcheck`, `/githubprepare`, `/githubsync`, release, migration and destructive operations remain closed;
- exact scope and current Git facts must still be checked locally.

## Owner interaction

Do not request approval of plans or current-scope repair iterations.
Ask the owner only for scope expansion, destructive/publication action, material-risk acceptance, unavailable capability or repeated no-progress failure.
