# Project Audit and Recovery

Use this when the user shows logs, screenshots, failed CI, inconsistent `.agy` state, or another model's claims.

## Audit checklist

1. What did the agent claim?
2. What evidence exists?
3. What files changed?
4. What checks actually ran?
5. What is missing?
6. Does current state match `.agy/PHASE_STATUS.json`?
7. Does current work match the latest user goal?
8. Are artifacts present and inspectable?
9. What is the next safe command?

## Recovery output

Produce:

- current verified state;
- completed / partial / missing / blocked;
- invalid claims;
- exact files or docs to inspect;
- corrected `next_required_command` recommendation;
- one recovery prompt for Antigravity.

## Do not

- accept stale `SHIP` reports;
- trust screenshots without checking code/state if possible;
- tell the user to continue implementation if phase state is unclear;
- recommend migration while active feature work is in progress.
