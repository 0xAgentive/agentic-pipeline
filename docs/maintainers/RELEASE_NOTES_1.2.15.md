# Agentic Pipeline 1.2.15 — Cross-Platform Validation and Stop Launch

This stable release supersedes 1.2.14 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fixes

- The Context Stop-hook command now starts with bare `powershell.exe` and carries its Unicode-safe relay through `-EncodedCommand`, avoiding first-token parsing failures while preserving UTF-8 stdin, stdout and the exact child exit status.
- Context Handoff rejects a generated Stop command longer than 8000 characters before installation, backup, hooks or task writes.
- The updater removes the obsolete generated `.cmd` wrapper transactionally; second apply remains byte-identical and injected failures restore the exact prior files and topology.
- Runtime, release-overlay, Action Bridge and hook-contract confinement use the host directory separator and the correct case comparison on Windows and Unix.
- Hermetic cleanup rejects volume roots, siblings and non-exact temporary leaves; runtime-handshake cleanup is bound to the exact selected fallback directory and generated filename pattern.
- Windows-only Context launch execution remains fully covered by a complete Distribution Integrity run on `windows-latest`; Ubuntu keeps the portable distribution contract.
- Action Bridge configures stdout and stderr as UTF-8 before emitting JSON or diagnostics, preventing English Windows code pages from rejecting Unicode project paths while retaining diagnostic-safe stderr escaping.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.15.
- Context Handoff engine/schema version remains 4.3.4.
- Runtime migration history under `runtime-1.2.9` and immutable maintainer documentation for 1.2.9 through 1.2.14 remain unchanged.
- Upgrade Local accepts 1.2.14 as a supported baseline and applies the complete 1.2.15 overlay before validation.

## Release artifacts

The release builds exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Both Windows and Ubuntu Distribution Integrity validators must pass without mutating the committed source tree.
