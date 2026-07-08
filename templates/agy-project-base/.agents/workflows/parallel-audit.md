---
description: Run independent read-only audit lanes and merge their findings.
---

# /parallel-audit

Read-only only.

Allowed lanes:

- reference integrity
- state machine
- security/privacy
- docs drift
- artifact contract
- visual/report evidence
- codebase-map-fast

No source writes.
No commits.
No formatting.
Each lane writes only audit artifacts under `.artifacts/parallel-audit/<run_id>/`.
Fixes happen later in a single `/nextphase`.
