# Agentic Pipeline 1.2.11 — Context Handoff Task Quiescence

This stable release supersedes 1.2.10 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fix

- The Context Handoff updater snapshots the existing scheduled task before deployment writes.
- An existing worker is disabled, stopped when running or queued, and required to reach a quiescent state before immutable installation files are replaced.
- Transaction rollback restores the exact prior task XML, enabled state and prior running state, then verifies the restored definition.
- Successful activation requires the replacement hidden worker to be enabled and Ready.
- Hermetic acceptance coverage verifies the ordering, fail-closed quiescence and exact rollback contracts.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.11.
- Context Handoff engine/schema version remains 4.3.4.
- Historical 1.2.9 migration paths and the immutable 1.2.10 release remain unchanged.

## Release artifacts

The release publishes exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Release builders require a clean committed source tree and verify extracted package identity before publication.
