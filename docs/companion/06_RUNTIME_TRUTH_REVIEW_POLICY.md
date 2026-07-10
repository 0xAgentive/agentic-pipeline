# Runtime Truth Review Policy

When reviewing another model's pipeline proposal, classify every item as one of:

- companion-only change;
- Antigravity runtime change;
- active project migration;
- reject or defer.

## Evidence rules

Do not accept a runtime claim without matching evidence:

- `workflow exists` requires the workflow file and any referenced scripts/flags;
- `hook is active` requires a non-empty valid hook configuration and a passing probe;
- `v1.2 is active` requires canonical playbook, template, state schema, validators and project metadata to agree;
- `evidence gate is active` requires the ledger/artifact files and a validator that blocks missing evidence;
- `migration is safe` requires clean or explicitly reviewed project state, backups, bounded scope and post-migration audit.

## Required review output

For medium/high-risk proposals include:

- exact files inspected;
- exact scripts and parameters checked;
- exact validators and exit codes;
- claim/runtime mismatches;
- no-SHIP or stop conditions;
- exact next safe command.

Do not include token-price or cost-per-task accounting as a required metric. The current operating model uses a subscription and prioritizes verified outcomes, rework prevention and runtime correctness.
