---
description: Fix only previously verified critical blockers in a bounded repair phase.
---

# /fixcritical

## Preconditions

- critical findings must come from a prior audit/security/visual/report/shipcheck result;
- each fix must have an exact path, evidence and verification command.

## Rules

- fix only listed critical blockers;
- no feature work or opportunistic refactor;
- run targeted regression checks;
- update evidence and state;
- stop after the bounded repair.

The next command is normally the audit/gate that found the blocker.
