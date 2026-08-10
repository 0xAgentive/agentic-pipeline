# Agentic Pipeline 1.2.19 — Atomic Result Authority Publication

This stable release supersedes 1.2.18 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fix

- Candidate publication no longer treats compiler-owned `NEXT_ACTION.json` as an immutable payload-authority input.
- Legacy 1.2.18 candidate manifests remain accepted, but post-publication validation permits only the exact intended `NEXT_ACTION` hash and continues to reject any change to real authority inputs.
- Journaled rollback still restores all four outputs on failure, while a second identical apply is verification-only and byte/mtime-identical.
- An executable real-shape regression covers the old bound next action, atomic replacement, exact post-write validation and idempotence.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.19.
- Context Handoff engine/schema version remains 4.3.4.
- Runtime migration history under `runtime-1.2.9` and immutable maintainer documentation for 1.2.9 through 1.2.18 remain unchanged.
- Upgrade Local accepts 1.2.18 as a supported baseline and applies the complete 1.2.19 overlay before validation.

## Release artifacts

The release builds exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Windows and Ubuntu Distribution Integrity validators must both pass without mutating the committed source tree.
