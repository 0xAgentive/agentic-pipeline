# Product Evidence Contract — Proportional Profiles

Evidence must be proportional to the active assurance mode.

## FLOW

Default evidence:

- `.agy/WORK_ITEM.json`;
- `.agy/RUN_RESULT.json`;
- the real product artifact when the task creates one.

No independent audit or evidence ZIP by default.

## GUARDED

Default evidence:

- work item;
- run result;
- one independent audit result;
- actual product artifacts and relevant product-specific validators.

## RELEASE

Release may additionally require manifests, provenance, hashes, extracted-package validation and release audit.

## Human output

Show status, concise changes, checks and artifact paths. Keep sizes and hashes inside machine manifests unless the user asks or integrity remains unresolved.

Do not duplicate one fact across many independently edited JSON and Markdown files.
