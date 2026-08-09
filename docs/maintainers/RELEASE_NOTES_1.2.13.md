# Agentic Pipeline 1.2.13 — Antigravity Hook Working Directory

This stable release supersedes 1.2.12 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fix

- Project lifecycle-hook commands are resolved relative to the `.agents` customization root, which Antigravity uses as the working directory for `.agents/hooks.json`.
- All owner-autonomy handlers now invoke `hooks/agentic_runtime_hook.cjs` without constructing the invalid `.agents/.agents/hooks` path.
- The canonical template and sample remain identical for every registered command and lifecycle event.
- Hermetic acceptance coverage executes the Stop handler from the exact `.agents` working directory, verifies the resolved runtime module and rejects duplicate handler registration.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.13.
- Context Handoff engine/schema version remains 4.3.4.
- Historical 1.2.9 migration paths and the immutable 1.2.10, 1.2.11 and 1.2.12 releases remain unchanged.

## Release artifacts

The release publishes exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Release builders require a clean committed source tree and verify extracted package identity before publication.
