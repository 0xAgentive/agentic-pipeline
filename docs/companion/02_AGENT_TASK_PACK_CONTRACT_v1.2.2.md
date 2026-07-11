# Agent Task Pack Contract v1.2.2

An Agent Task Pack is the smallest complete instruction package that lets an executor work safely without inventing scope.

## Small low-risk task

Include:

- goal;
- context;
- allowed scope;
- forbidden scope;
- done criteria;
- checks;
- stop conditions;
- exact next action.

## Important or medium/high-risk task

Include these blocks.

### 1. Runtime Handshake Block

- pipeline package/runtime version;
- project/workspace/Git/state/artifact roots;
- command inventory hash;
- available commands;
- current phase/status;
- `next_required_command`;
- commands allowed now;
- routing validity.

If the handshake is unavailable, do not emit an executable slash command.

### 2. Frozen Phase Contract Block

- phase ID and contract version;
- goal and non-goals;
- risk track;
- evidence level;
- allowed and forbidden paths;
- required outputs and checks;
- acceptance criteria;
- blocking conditions;
- non-blocking debt categories;
- repair budget;
- exact next allowed commands;
- contract hash.

Acceptance criteria must be fixed before implementation starts. New findings after execution must be classified; they may not silently expand the current contract.

### 3. Risk and Trust Block

- privacy/security boundaries;
- untrusted inputs;
- tool/permission profile;
- irreversible or high-impact actions;
- required human decisions;
- rollback trigger.

### 4. Evidence Block

- evidence level E0-E4;
- deterministic commands and expected exit codes;
- required artifacts;
- provenance requirements;
- VisualQA / ReportQA / SecurityQA / ArtifactAudit where applicable;
- no-SHIP conditions.

### 5. Result Authority Block

- path to `PHASE_RESULT.json` or equivalent;
- fields that the final response may quote;
- fields that must be reported as `unverified` when absent;
- rule that hashes, sizes, durations, test counts and next commands are never reconstructed from memory.

### 6. Repair Budget Block

Default for one subsystem:

- one audit;
- one `fixcritical` repair;
- one verification;
- maximum two total repairs in one phase.

After budget exhaustion, require a human decision: continue, accept debt, defer, or redesign.

## Required end of every execution prompt

- implement only this phase;
- do not start the next phase;
- run the listed checks;
- report changed files, commands, exit codes, risks and artifacts;
- derive final status from machine-readable results;
- provide exactly one next action;
- stop.

## Forbidden defaults

- no unrestricted “build everything” instruction;
- no invented slash command;
- no moving acceptance criteria after execution;
- no financial/token cost fields as mandatory output;
- no automatic migration of active projects;
- no declaration of `SHIP` from prose alone.
