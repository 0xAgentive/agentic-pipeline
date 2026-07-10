---
name: release-evidence-packaging
description: Use when preparing a deterministic evidence bundle for audit, review, release, or handoff without publishing automatically.
---

# Release Evidence Packaging

Package only approved evidence:
- command outputs and exit codes;
- test/build/lint/parser results;
- screenshots or report artifacts;
- manifests and checksums;
- changed-file list;
- residual risks and rollback notes.

Do not include secrets, raw sensitive data, local absolute paths, private logs, or unredacted identifiers.

Do not publish or push automatically.
