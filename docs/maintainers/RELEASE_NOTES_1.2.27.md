# Agentic Pipeline 1.2.27 — Ecosystem Autonomy and Handoff Alignment

This stable release supersedes 1.2.23 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fix

- Restart-bootstrap creation preserves every allowlisted zero-byte `SESSION_DELTA` member as an exact zero-byte archive member instead of failing PowerShell parameter binding or silently omitting it.
- `INCLUDED_FILES.json` and `MANIFEST.json` bind the preserved member with size `0` and the SHA-256 digest of an empty byte sequence.
- A single strict UTF-8 reader is used for initial copying, existing-artifact verification, staged privacy scanning and final extracted-ZIP scanning; malformed text and secret-bearing content remain fail closed.
- Required authority inputs may not be empty. Session evidence must contain at least one non-empty delta or a valid `NO_NEW_EVENTS` receipt.
- A hermetic real-generator regression covers mixed empty/non-empty evidence, exact manifest binding, idempotent reuse, receipt-only acceptance, all-empty rejection, required-empty rejection and forbidden empty names as a Distribution Integrity core gate.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.27.
- Context Handoff engine/schema version remains 4.3.4.
- Runtime migration history under `runtime-1.2.9` and immutable maintainer documentation through 1.2.23 remain unchanged.
- Upgrade Local accepts 1.2.23 as a supported baseline and applies the complete 1.2.27 overlay before validation.

## Release artifacts

The release builds exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Windows and Ubuntu Distribution Integrity validators must both pass without mutating the committed source tree.
