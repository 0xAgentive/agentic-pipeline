# Agentic Pipeline 1.2.23 — Exact Handoff Root Entry

This stable release supersedes 1.2.22 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fix

- Restart-bootstrap creation now selects `COMPANION_ENTRY.md` only by its exact archive-root full name.
- A valid handoff may contain both root `COMPANION_ENTRY.md` and `SOURCE_SNAPSHOTS/.../.agy/COMPANION_ENTRY.md`; snapshot copies no longer create false ambiguity.
- Raw ZIP full names are validated before extraction. Missing or wrong-case root entries, duplicate or case-colliding paths, backslash or dot aliases, and every directory-only entry fail closed.
- Extraction performs a second exact-root check and never uses recursive basename or suffix lookup.
- A hermetic acceptance regression covers the valid root-plus-snapshot shape and all rejected ambiguity forms, and runs as a Distribution Integrity core gate.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.23.
- Context Handoff engine/schema version remains 4.3.4.
- Runtime migration history under `runtime-1.2.9` and immutable maintainer documentation through 1.2.22 remain unchanged.
- Upgrade Local accepts 1.2.22 as a supported baseline and applies the complete 1.2.23 overlay before validation.

## Release artifacts

The release builds exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Windows and Ubuntu Distribution Integrity validators must both pass without mutating the committed source tree.
