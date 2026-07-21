---
description: Execute one owner-approved work item autonomously through implementation, current-scope repair and the required audit.
---

# /nextphase

## Goal

Advance the current owner-approved work item without requiring plan approval or repeated owner confirmation.

## Authority

Read:

- `.agy/WORK_ITEM.json`;
- `.agy/FLOW_POLICY.json`;
- `.agy/EXECUTION_SCOPE.json` when present;
- `.agy/RUN_RESULT.json` when present;
- `.agy/RUNTIME_HANDSHAKE.json` when present;
- Git status and current branch.

If no active work item exists, create one from the current owner goal with:

```powershell
pwsh -NoProfile -File scripts/windows/companion/New-WorkItem.ps1 -ProjectRoot . -Goal "<owner goal>" -AssuranceMode <flow|guarded|release> -Apply
```

Do not ask the owner to approve an Implementation Plan.

## Assurance modes

- `flow`: targeted verification; no independent audit unless a blocker requires it.
- `guarded`: product-specific checks plus one independent read-only audit.
- `release`: strict release gates; publication remains a separate owner decision.

## Execution

1. Perform read-only discovery.
2. Create exact `.agy/EXECUTION_SCOPE.json` before the first edit. Do not guess paths from a remote task brief.
3. Validate the scope locally.
4. Implement only the approved goal.
5. Run the checks appropriate to the assurance mode.
6. Write one `.agy/RUN_RESULT.json`.
7. If current-scope product blockers remain, continue through the `/fixcritical` procedure without requesting owner approval.
8. If verification is required, continue through the `/auditphase` procedure.
9. Continue while each repair produces measurable progress.
10. Stop on accepted result or a hard stop.

## Hard stops

Stop only when:

- a required change is outside the approved goal or execution scope;
- a destructive, publication or external action is required;
- the same deterministic failure repeats without measurable progress;
- an unavailable external capability blocks verification;
- framework/runtime migration is required;
- a material risk requires owner acceptance.

## Output

Report product status, material blockers, checks and up to five artifact paths. Do not print hashes or sizes unless an integrity failure is the blocker.
