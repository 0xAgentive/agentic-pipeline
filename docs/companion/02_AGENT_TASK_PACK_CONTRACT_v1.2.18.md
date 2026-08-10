# Agent Task Pack Contract v1.2.18

The Companion emits one owner-approved single-file JSON action packet. The active filename is:

`AGENTIC_ACTION_PACKET_<project>_<timestamp>.json`

The JSON contains the machine contract, the full technical task in `technical_task_markdown`, and the four-section owner summary in `owner_summary_ru`. A ZIP is not required and must not be requested from the Antigravity attachment dialog.

## Executor discovery

Before the first write, the executor discovers the exact project root, worktree, branch, baseline HEAD, Git state, active work-item identity, route inventory and available project-local tools. The packet may use `scope_binding: executor_discovery`; discovery does not permit writes until the project-local transaction and pre-write validator pass.

## owner_interaction_policy

Every packet uses `owner_interaction_policy: hard_stop_only`. Routine implementation, correction, audit, verification, tool retry, evidence rebuild and current-scope control-plane work do not require another owner approval. Only a true product or risk decision may be requested.

## New work item

A new-work packet includes the immutable goal, acceptance outcomes, non-goals, risk hints and audit dimensions. Activation creates the work item, scope, lease, stage firewall, handshake and initial route atomically.

## Existing work item

A continuation packet carries the exact work-item ID and goal epoch. It contains only the technical delta and route; it never rewrites the owner brief or asks the owner to manage internal iteration state.

## Completion

The executor completes the current route, records actual command results, updates progress and findings, and publishes the next action or authoritative closure. The owner receives only the plain-language result. The packet is complete only when its schema validates, its capability matches the registered project, its time window is valid and its full task is present.
