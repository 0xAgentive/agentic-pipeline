# Agentic Pipeline 1.2.14 — Context Handoff Command Wrapper

This stable release supersedes 1.2.13 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fix

- The generated Antigravity Stop-hook command now invokes an ASCII `.cmd` wrapper instead of directly quoting a Unicode executable path inside the hook command.
- The wrapper delegates to the hidden Windows PowerShell relay, preserving hook stdin, stdout and the exact child exit status across Unicode and space-containing paths.
- Wrapper creation, update and removal participate in the existing transaction, including byte-aware idempotence and exact rollback.
- Hermetic acceptance coverage executes the installed command through `cmd.exe /d /s /c`, verifies UTF-8 payload forwarding, requires an unchanged second apply and injects a rollback fault.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.14.
- Context Handoff engine/schema version remains 4.3.4.
- Historical 1.2.9 migration paths and the immutable 1.2.10, 1.2.11, 1.2.12 and 1.2.13 releases remain unchanged.

## Release artifacts

The release publishes exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Release builders require a clean committed source tree and verify extracted package identity before publication.
