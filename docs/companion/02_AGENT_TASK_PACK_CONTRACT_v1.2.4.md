# Companion Work Brief Contract v1.2.4

The Companion creates exactly one semantic brief per owner-approved work item.

## Initial brief

```json
{
  "goal": "...",
  "assurance_mode": "flow|guarded|release",
  "stage_profile": "general|protocol_freeze|analytical_validation|empirical_validation",
  "acceptance": [],
  "non_goals": [],
  "risk_hints": [],
  "hard_stops": [],
  "owner_interaction_policy": "hard_stop_only",
  "scope_binding": "executor_discovery"
}
```

The brief is immutable after owner approval. A revision is allowed only after an owner requirement change or a proven outside-scope dependency.

## Executor discovery

Before the first write, Antigravity performs live read-only discovery and binds the exact project root, worktree, branch, baseline HEAD, Git state, work item, goal epoch and execution scope. The Companion defines semantic acceptance and risk boundaries; it does not guess exact paths or source allowlists.

A wrong project, worktree or owner-goal fingerprint is a material hard stop. Expected edits inside a valid execution lease do not invalidate the lease.

## Subsequent iterations

Do not regenerate the brief. Return only:

- work item identity;
- new, changed and resolved material finding IDs;
- current route;
- repair-batch and audit-budget state;
- owner action only for a hard stop.

Antigravity persists details in `FINDINGS.json`, `FINDING_DELTA.json` and `REPAIR_DELTA.json`.

## Completion

Completion is compiled from the execution lease, verification receipts, finding lifecycle, audit coverage, reviewer attestation, repair budget and stage firewall. A work item may close as accepted, completed with verification debt, or blocked by one material hard stop. Verification debt blocks release of the affected result but does not automatically block the next owner-approved product goal.

Do not continue evidence-packaging or audit-authority repair after the bounded convergence budget is exhausted when product blockers are zero.

## Limits

- no guessed exact paths;
- no precomputed hashes, test totals or artifact sizes;
- no second semantic task pack for repair or audit;
- no more than ten acceptance outcomes and eight non-goals;
- no evidence-packaging work unless it is the product goal or a release boundary;
- one comprehensive first audit and no more than three grouped GUARDED repair batches by default.
