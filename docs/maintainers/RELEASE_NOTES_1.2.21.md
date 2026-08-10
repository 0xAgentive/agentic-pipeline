# Agentic Pipeline 1.2.21 — Hosted Runner Reparse Fixture

This stable release supersedes 1.2.20 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fix

- The T66 Windows reparse-point regression now canonicalizes its temporary environment root before identifying the protected verification directory.
- Hosted runners whose temporary directory is reached through a junction therefore test the same canonical path used by `confined_project_file`.
- Production confinement remains fail closed: a real reparse-point path component is still rejected as `authority_path_not_safe_file`.
- The complete 1.2.20 semantic verification-test binding and its positive and negative cases remain active.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.21.
- Context Handoff engine/schema version remains 4.3.4.
- Runtime migration history under `runtime-1.2.9` and immutable maintainer documentation for 1.2.9 through 1.2.20 remain unchanged.
- Upgrade Local accepts 1.2.20 as a supported baseline and applies the complete 1.2.21 overlay before validation.

## Release artifacts

The release builds exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Windows and Ubuntu Distribution Integrity validators must both pass without mutating the committed source tree.
