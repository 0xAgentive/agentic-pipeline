# Agentic Pipeline 1.2.16 — Context Handoff Scheduler Idempotence

This stable release supersedes 1.2.15 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fixes

- Context Handoff uses one bounded task-health wait for both idempotent apply and canary verification instead of treating a split scheduler read as a terminal failure.
- The wait accepts only the known transient `Queued`, `Running` and `0x41301` scheduler observations, then requires the installed task to be enabled and reach `Ready` with result `0`.
- A terminal non-zero result fails immediately, while persistent in-progress states fail after the bounded timeout; neither path can report a false success.
- Deterministic injected scheduler adapters cover the real `Queued` to `Running` to split-read `Ready/0x41301` to `Ready/0` sequence, timeout and immediate terminal failure without mutating Scheduled Tasks.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.16.
- Context Handoff engine/schema version remains 4.3.4.
- Runtime migration history under `runtime-1.2.9` and immutable maintainer documentation for 1.2.9 through 1.2.15 remain unchanged.
- Upgrade Local accepts 1.2.15 as a supported baseline and applies the complete 1.2.16 overlay before validation.

## Release artifacts

The release builds exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Both Windows and Ubuntu Distribution Integrity validators must pass without mutating the committed source tree.
