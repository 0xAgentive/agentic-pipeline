# Project Audit and Corrective Routing

Use this when the user shows logs, screenshots, failed CI, inconsistent state or another model's completion claim.

## Audit checklist

1. What exactly was claimed?
2. Which claims are implementation claims, evidence claims, scientific claims or release claims?
3. What machine-readable evidence exists?
4. What files changed and what checks actually ran?
5. Does current state match `.agy/PHASE_STATUS.json` and the frozen phase contract?
6. Is the reported slash command present in current runtime inventory?
7. Are findings new blockers, next-phase requirements, deferred debt or false positives?
8. Has the repair budget been exhausted?
9. What is the one safe next action?

## Command routing

- `/auditphase`: read-only reconciliation of state, claims, evidence and blockers;
- `/fixcritical`: repair only blockers already confirmed by an audit/gate;
- `/landing`: restore state/handoff only; no implementation;
- `/nextphase`: implement one approved phase with a frozen contract;
- `/probephase`: bounded uncertainty reduction before architecture or implementation;
- `/fastpatch`: only when the deterministic fastpatch gate allows it.

There is no default `/recovery` command. Do not emit it unless the current runtime inventory explicitly contains it.

## Corrective output

Produce:

- current verified state;
- claim/evidence matrix;
- completed / partial / missing / blocked;
- invalidated or unsupported claims;
- blocker taxonomy;
- repair-budget status;
- corrected state recommendation;
- exactly one next action.

## Do not

- accept stale `SHIP` or `completed` prose;
- invent a workflow;
- add new acceptance criteria retroactively without classification;
- start another repair loop after the budget is exhausted;
- block low-risk research for delivery polish that does not affect validity;
- equate implementation alignment with empirical/scientific validation;
- recommend project migration while active feature work is in progress.
