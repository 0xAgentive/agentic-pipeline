# Project Audit and Corrective Routing

Use this when logs, artifacts, CI or another model's completion claim require reconciliation.

## Audit checklist

1. What product outcome was claimed?
2. Which claims are product, verification, scientific or release claims?
3. Which machine result is current for this `work_item_id`?
4. What changed and what deterministic checks actually ran?
5. Are blockers product, verification, release, service warning or cosmetic?
6. Is the requested workflow present in project-local inventory?
7. Does external drift invalidate the execution lease?
8. Is current-scope repair still producing measurable progress?
9. What is the one current workflow or hard stop?

## Routing

- `/nextphase`: execute the owner-approved work item after local scope discovery;
- `/fixcritical`: repair current-scope product blockers automatically;
- `/auditphase`: read-only verification or protected GUARDED audit;
- `/fastpatch`: low-risk FLOW only after the deterministic gate;
- `/landing`: legacy recovery/state handoff;
- `/shipcheck`: RELEASE only.

There is no default `/recovery` command.

## Automatic repair

Continue without owner approval while the blocker remains inside scope and each iteration changes the failing check or relevant diff. Stop once for outside-scope need, unavailable capability, destructive/publication action, framework migration, material-risk acceptance or repeated no-progress failure.

## Corrective output

Return:

- current product status;
- material blockers only;
- current workflow/result;
- owner action only for a hard stop;
- up to five artifact names and absolute paths.

Do not create a new brief for the same current-scope repair.
