# Agentic Pipeline 1.2.20 — Semantic Verification Test Binding

This stable release supersedes 1.2.19 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fix

- Context Handoff now compares the compiler's verification-test projection field by field, including semantic UTC timestamp equality.
- An omitted optional `supersedes_run_id` or `summary` is equivalent only to the compiler's canonical empty value; a different non-empty value still fails closed.
- Required status, run identity, exit code, evidence path, SHA-256 and size remain exact and are checked before ZIP, UX or clipboard publication.
- An executable regression reproduces the 1.2.19 natural Stop failure and proves both the compatible canonical case and a rejected lineage mismatch.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.20.
- Context Handoff engine/schema version remains 4.3.4.
- Runtime migration history under `runtime-1.2.9` and immutable maintainer documentation for 1.2.9 through 1.2.19 remain unchanged.
- Upgrade Local accepts 1.2.19 as a supported baseline and applies the complete 1.2.20 overlay before validation.

## Release artifacts

The release builds exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Windows and Ubuntu Distribution Integrity validators must both pass without mutating the committed source tree.
