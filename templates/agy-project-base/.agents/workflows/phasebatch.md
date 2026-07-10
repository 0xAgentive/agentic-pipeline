---
description: Disabled-by-default multi-phase mode. Use only after explicit human unlock.
---

# /phasebatch

Default result: `BLOCKED`.

Do not run multiple write phases unless all of the following are explicitly true:
- the user requested batch execution;
- `.agy/PHASE_STATUS.json` has `batch_allowed: true`;
- the worktree is clean;
- phases have non-overlapping scopes and deterministic checks;
- rollback/checkpoint strategy is documented;
- no sensitive, security, release or architecture gate requires human review.

Otherwise recommend `/nextphase`.
