# Work-Item Scope and Repair Convergence

Legacy phase contracts remain supported, especially for RELEASE work.

For FLOW/GUARDED daily work, use:

- `WORK_ITEM.json` for stable owner authorization;
- `EXECUTION_SCOPE.json` for exact live paths;
- `RUN_RESULT.json` for current result.

## Repair policy

Do not require owner approval after a fixed number of repair cycles.
Continue while:

- the blocker is inside scope;
- each iteration changes the failing evidence or implementation meaningfully;
- required capabilities are available.

Stop for:

- outside-scope requirement;
- destructive/publication action;
- unavailable capability;
- material-risk acceptance;
- framework/runtime migration;
- repeated identical failure without measurable progress.

A same-failure threshold is a safety fuse, not the normal workflow.
