---
name: quota-safe-continuity
description: Preserves recoverability during long or risky Antigravity tasks. Use when the user mentions quota, credits, checkpoint, landing, recovery, resume, handoff, interrupted work, or when a task is multi-phase, multi-file, migration/dependency/browser/MCP-heavy, or likely to exceed context/quota.
---

# Quota-Safe Continuity

Preserve recoverability without wasting context.

## Phase protocol
1. Define the smallest useful phase and its verification check.
2. Execute only that phase.
3. Verify with the cheapest meaningful check.
4. Update `.agy/AGENT_STATE.md` and `.agy/RECOVERY_PROMPT.md` only at phase boundaries, before risky/long actions, or in Landing Mode.
5. Stop or ask for confirmation when the next phase is broad, risky, or likely to consume significant quota.

## `.agy/AGENT_STATE.md` template
```md
# Agent State

Status: IN_PROGRESS | PARTIAL_RECOVERABLE | VERIFYING | DONE_VERIFIED
Last updated: <UTC timestamp>

## Request
<original user goal and success criteria>

## Completed
- <completed work>

## Changed files
- `<path>` — <purpose/status>

## Verification
- `<command>` — PASS/FAIL/NOT_RUN: <short result>

## Incomplete
- <remaining work>

## Risks / assumptions
- <risk or assumption>

## Rollback
- <how to revert or recover>

## Next steps
1. <exact next action>
```

## `.agy/RECOVERY_PROMPT.md` template
```md
Resume this Antigravity task from the local repo state.

First read:
1. `.agy/AGENT_STATE.md`
2. `.agy/MCP_PROFILE.md` if MCP tools were used or configured
3. `.agy/LATEST_CHECKPOINT.md`
4. `git status --short`
5. The changed files listed in AGENT_STATE

Do not redo completed work unless verification contradicts it.
Continue from the first item under "Next steps".
Before broad changes, inspect the current diff and run the listed verification command if cheap.
If state is inconsistent, enter Landing Mode and repair the checkpoint before implementation.
```

## Landing Mode
When entering Landing Mode, do no new implementation. Persist state, ensure the latest patch/checkpoint exists, summarize completed and incomplete work, write a recovery prompt, and label the result `PARTIAL / RECOVERABLE CHECKPOINT` unless fully verified.
