# Runtime Truth Review Policy

When reviewing a proposal, classify every item as:

- companion-only change;
- runtime change;
- active-project change or migration;
- optional pack;
- reject;
- defer.

## Runtime claim rules

Do not accept a runtime claim without matching evidence:

- `command exists` requires current command inventory and workflow file;
- `workflow works` requires referenced scripts/parameters and a passing validator;
- `hook is active` requires valid non-empty configuration and a real hook probe;
- `evidence gate is active` requires schemas, writers, validator and a failing negative fixture;
- `migration is safe` requires bounded scope, backup and post-migration audit;
- `completed` requires phase-result fields, not terminal prose.

## Required review output

For medium/high-risk proposals include:

- runtime handshake source;
- exact files inspected;
- exact commands and exit codes;
- claim/runtime mismatches;
- blocker categories;
- repair budget;
- stop/no-SHIP conditions;
- one exact next action.

Do not require token-price or cost-per-task accounting.
