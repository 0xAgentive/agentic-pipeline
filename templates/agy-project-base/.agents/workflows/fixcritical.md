---
description: Repair confirmed current-scope product blockers autonomously until verified or a hard stop is reached.
---

# /fixcritical

## Preconditions

- an owner-approved `.agy/WORK_ITEM.json` exists;
- blockers belong to the current goal and exact execution scope;
- release/publication actions are not performed here.

## Rules

1. Read `.agy/RUN_RESULT.json`, findings and failing evidence.
2. Repair only confirmed product blockers.
3. Treat verification blockers as audit work, not feature expansion.
4. Treat service metadata drift as auto-repairable and non-blocking.
5. Run targeted regression checks after each repair.
6. Update `.agy/RUN_RESULT.json` rather than creating a new task pack.
7. Continue automatically while the blocker signature changes or evidence improves.
8. Stop only on PASS, outside-scope need, unavailable capability, destructive/publication decision or repeated no-progress failure.

Do not ask the owner to approve another repair iteration.
Do not create another numbered repair phase.
Do not display hashes unless corruption remains unresolved.
