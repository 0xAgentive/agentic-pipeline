---
description: Read-only audit of repository state, claims, evidence and blockers.
---

# /auditphase

## Mode

Read-only. Do not repair findings in this workflow.

## Read

- `.agy/PHASE_STATUS.json`
- `.agy/AGENT_STATE.md`
- `.agy/RECOVERY_PROMPT.md`
- relevant specification, plan, rules, workflows, diffs, tests and artifacts
- git status and recent evidence

## Verify

- requested work matches `next_required_command`;
- state files parse and agree;
- claimed files/scripts/artifacts exist;
- deterministic checks support claims;
- dirty files belong to the expected scope;
- unresolved requirements or missing evidence block readiness.

## Output

- VERIFIED or BLOCKED;
- findings with severity, path and evidence;
- commands run with exit codes;
- corrected state recommendation;
- one exact next command.

Stop after the audit.
