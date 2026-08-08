# Agentic Pipeline 1.2.10 — Lossless Legacy Runtime Migration

This stable release supersedes 1.2.9 without rewriting it. It binds Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff to one immutable version and source commit.

## Correctness and regression closure

- The six-file post-validation failure was traced to an external recovery overlay that copied LF payload bytes over a CRLF checkout even when no changes were expected.
- Candidate overlay now skips empty and Git-blob-identical payloads, then uses Git attributes for expected changed files.
- Every validator is covered by before/after tracked-byte hashes, clean-status checks and a one-byte negative detection probe.
- Native process output keeps stdout and stderr separate; Git machine paths use NUL-delimited output.
- Legacy StrictMode state shapes and optional Action Packet fields have executable Windows regressions.

## Deployment

- The updater migrates the exact legacy findings shape used by active projects, preserves the original bytes in versioned history, rejects unknown variants and rolls back atomically.
- Runtime migration is allowlisted, transactional, product-source preserving and verification-only on its second identical run.
- External Action Packets are token-free. The installed Bridge resolves the exact local project and injects its capability only into local materialization.
- The complete Context Handoff 4.3.4 engine is packaged under ecosystem version 1.2.10 and excludes raw Action Packets and Bridge capability files.
- Companion deployment and restart bootstrap are exact-asset, manifest-bound and secret-free.
