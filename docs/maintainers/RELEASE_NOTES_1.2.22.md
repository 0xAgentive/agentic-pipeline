# Agentic Pipeline 1.2.22 — Causal Verification Ordering

This stable release supersedes 1.2.21 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fix

- Result-authority timestamps must use strict ISO-8601 with an explicit `Z` or numeric offset; locale-formatted values are rejected instead of being reinterpreted.
- Every required verification test must declare `started_at_utc`.
- Candidate generation and candidate-status publication must both occur no later than the start of every required test, closing the post-test candidate laundering gap.
- Candidate publication is covered by a byte-for-byte regression proving it cannot mutate or rebind an existing verification receipt.
- Context Handoff returns sanitized, specific timestamp/order reasons and independently enforces the same causal contract as the compiler.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.22.
- Context Handoff engine/schema version remains 4.3.4.
- Runtime migration history under `runtime-1.2.9` and immutable maintainer documentation for 1.2.9 through 1.2.21 remain unchanged.
- Upgrade Local accepts 1.2.21 as a supported baseline and applies the complete 1.2.22 overlay before validation.

## Release artifacts

The release builds exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Windows and Ubuntu Distribution Integrity validators must both pass without mutating the committed source tree.
