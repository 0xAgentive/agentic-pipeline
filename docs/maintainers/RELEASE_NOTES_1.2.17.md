# Agentic Pipeline 1.2.17 — Quiescent Verified Handoff

This stable release supersedes 1.2.16 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fixes

- Result-authority compilation now fails before writes when required arguments are missing, runs through one project-scoped singleton, coalesces identical requests and cancels the complete worker tree at a bounded timeout.
- The compiler captures and fingerprints every authority input, revalidates it immediately before publication and writes the exact verification receipt, run result, closure state and next action as one journaled transaction with exact rollback and interrupted-run recovery.
- Required test evidence is confined to non-reparse files below `.agy/verification/**`; path, size, SHA-256 and completion time are bound to the current work item, candidate manifest and Git HEAD. Unsafe, secret-like, stale or tampered inputs fail closed.
- Context Handoff exports and validates that exact receipt and its evidence, rejects stale pre-repair results and keeps Stop publication quiescent while compilation is active.
- Executable regressions cover unsafe hook invocation, receipt/candidate/input races, tamper, privacy confinement, singleton/coalescing, timeout tree termination, crash recovery and rollback.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.17.
- Context Handoff engine/schema version remains 4.3.4.
- Runtime migration history under `runtime-1.2.9` and immutable maintainer documentation for 1.2.9 through 1.2.16 remain unchanged.
- Upgrade Local accepts 1.2.16 as a supported baseline and applies the complete 1.2.17 overlay before validation.

## Release artifacts

The release builds exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Both Windows and Ubuntu Distribution Integrity validators must pass without mutating the committed source tree.
