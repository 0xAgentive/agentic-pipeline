# Agentic Pipeline 1.2.12 — Context Handoff Unicode Launcher

This stable release supersedes 1.2.11 without rewriting its public tag or release. Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff use one ecosystem version and one immutable source commit.

## Root fix

- The generated hidden-worker VBS launcher is serialized as UTF-16LE with a byte-order mark, so Windows Script Host preserves non-ASCII `pythonw.exe` paths.
- Update planning compares the launcher as exact bytes, including its encoding, before deciding whether a deployment write is required.
- A byte-identical second apply performs no launcher write, preserves its modification time and creates no backup.
- Hermetic acceptance coverage executes the generated launcher through `cscript.exe` under a Unicode path and verifies successful execution, idempotence and exact transactional rollback.

## Compatibility

- Action Packet and Bridge schema versions remain independently versioned at 1.2.9; their ecosystem binding is 1.2.12.
- Context Handoff engine/schema version remains 4.3.4.
- Historical 1.2.9 migration paths and the immutable 1.2.10 and 1.2.11 releases remain unchanged.

## Release artifacts

The release publishes exact commit-bound Pipeline, Companion, runtime overlay, Action Bridge and Context Handoff assets. Release builders require a clean committed source tree and verify extracted package identity before publication.
