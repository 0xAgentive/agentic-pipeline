# Runtime Handshake and Command Routing

Project-local inventory remains command authority.

## Work-item routing

When `.agy/WORK_ITEM.json` is valid, owner-approved and active, the runtime selects FLOW, GUARDED or RELEASE.

FLOW/GUARDED may use `degraded_product_execution` when legacy phase metadata is stale or schema-invalid but:

- project inventory is authoritative;
- runtime is compatible;
- the work item is owner-approved;
- execution scope is not externally invalidated;
- release and publication commands remain closed.

Routes:

- implementation ready → `/nextphase`;
- product blocker → `/fixcritical`;
- verification blocker or GUARDED audit → `/auditphase`;
- eligible small FLOW change → `/fastpatch`;
- RELEASE acceptance → `/shipcheck`.

`SHIP` is terminal for the current work item only. A new owner-approved work item reopens product routing.

## Degraded route restrictions

Never allow `/shipcheck`, `/githubprepare`, `/githubsync`, migration or destructive actions from degraded product execution.

## Staleness

Expected executor edits do not invalidate their own work-item authorization. External branch change, owner-goal change, outside-scope edits, runtime migration or a new material risk do invalidate it.
