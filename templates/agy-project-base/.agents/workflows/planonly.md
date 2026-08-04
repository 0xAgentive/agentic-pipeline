---
description: Create the one immutable owner-approved work brief and stop before implementation.
---

# /planonly

Create or validate exactly one work brief for the new owner goal.

Include goal, assurance mode, stage profile, acceptance outcomes, non-goals, risk hints, hard stops, `hard_stop_only` owner policy and `executor_discovery` scope binding.

Lock the brief fingerprint in `WORK_ITEM.json`. Do not create a second brief for repair or audit. Subsequent iterations use finding and repair deltas.

Do not implement product code in this workflow.
