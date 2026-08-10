# Agentic Pipeline 1.2.18 — Candidate Manifest Multi-Record Integrity

This stable release supersedes 1.2.17 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fix

- Candidate-manifest publication now converts Git status records to structured objects before sorting, so modified, deleted, renamed and Unicode paths cannot collapse to one false-green record.
- The publisher consumes NUL-delimited porcelain v2 output, emits UTF-8 machine JSON and rejects duplicate or case-colliding paths before writing authority state.
- An executable multi-record regression verifies the exact leased candidate set, the separate ambient set, published manifest bytes and status hash while proving zero live writes and source-checkout mutation.
- The 1.2.17 quiescent receipt, bounded compiler, atomic Context Handoff and raw test-evidence chain remain mandatory and unchanged.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.18.
- Context Handoff engine/schema version remains 4.3.4.
- Runtime migration history under `runtime-1.2.9` and immutable maintainer documentation for 1.2.9 through 1.2.17 remain unchanged.
- Upgrade Local accepts 1.2.17 as a supported baseline and applies the complete 1.2.18 overlay before validation.

## Release artifacts

The release builds exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Windows and Ubuntu Distribution Integrity validators must both pass without mutating the committed source tree.
