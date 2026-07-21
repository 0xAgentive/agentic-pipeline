# Companion Work Brief Contract v1.2.3

The Companion creates one compact semantic brief per owner-approved work item.

## Required fields

```json
{
  "goal": "...",
  "assurance_mode": "flow|guarded|release",
  "acceptance": [],
  "non_goals": [],
  "risk_hints": [],
  "hard_stops": [],
  "owner_interaction_policy": "hard_stop_only",
  "scope_binding": "executor_discovery"
}
```

## Limits

- one brief per work item;
- no repeated owner plan approval;
- no exact source allowlist without live source authority;
- no fixed test counts, durations, hashes or artifact sizes;
- no release-grade evidence in FLOW;
- no more than ten acceptance outcomes and eight non-goals;
- no destructive rollback instructions;
- no additional task pack for a current-scope repair.

## Executor discovery

Before the first edit, Antigravity inspects the live workspace and creates `.agy/EXECUTION_SCOPE.json` with exact paths. If a required change is outside the approved semantic goal, stop once with an outside-scope blocker.

## Completion

The brief remains stable while implementation, repair and audit proceed. A new revision is allowed only after an owner requirement change or a proven outside-scope dependency.
