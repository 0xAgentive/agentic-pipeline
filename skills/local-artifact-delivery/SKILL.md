---
name: local-artifact-delivery
description: Use when presenting local files, archives, installers, reports, logs, or other artifacts to the owner. Show only primary artifacts compactly and keep machine metadata internal.
---

# Local Artifact Delivery — Compact Primary Artifacts

This Skill supersedes earlier versions that required a verbose metadata block for every local file.

Default owner-facing output:

```text
АРТЕФАКТЫ

- <short purpose> — <complete native absolute path>
```

Rules:

1. Show only artifacts the owner is expected to open, run, install, inspect, or transfer.
2. Show at most three primary artifacts unless the owner asks for more.
3. Use exactly one artifact section and deduplicate paths.
4. Do not show project-relative paths, `Exists`, byte sizes, hashes, `NOT_VERIFIED`, PowerShell commands, or Explorer commands by default.
5. Do not list `RUN_RESULT.json`, `AUDIT_RESULT.json`, logs, manifests, sidecars, or temporary reports when a primary product artifact exists.
6. Keep full metadata inside machine-readable manifests.
7. Show verified size/hash only for explicit user request, unresolved corruption, exact candidate disambiguation, or RELEASE identity.
8. Never show `SHA-256: NOT_VERIFIED`. If integrity is required and unavailable, report one short blocker instead of a metadata dump.
9. Never use `file://`, URL-encoded local paths, or Markdown-link-only local paths.
