---
description: Verify that required phase artifacts exist, are indexed, and match checksums.
---

# /artifactaudit

Read-only unless explicitly asked to generate an evidence archive.

Check:

- `.agy/ARTIFACT_INDEX.ndjson`
- `.artifacts/**/ARTIFACT_MANIFEST.json`
- referenced files exist
- SHA-256 and sizes match
- required artifacts for current phase are present

If a required artifact is missing, block `/shipcheck`.
