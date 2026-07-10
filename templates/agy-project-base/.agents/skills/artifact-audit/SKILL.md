---
name: artifact-audit
description: Use when validating generated artifacts, manifests, checksums, paths, sizes, or cross-format consistency before shipcheck.
---

# Artifact Audit

Verify only material artifacts required by the current phase.

Check:
- referenced files exist;
- manifest paths are repository-relative or approved artifact paths;
- SHA-256 and file size match when recorded;
- PDF/HTML/ZIP/CSV/JSON/MD outputs agree on core facts;
- sensitive paths, IDs, raw logs and forbidden claims are absent;
- missing artifacts block readiness.

Return deterministic findings and artifact paths. Do not implement product changes in this skill.
