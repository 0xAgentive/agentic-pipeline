# Verification Gates — Materiality

Classify findings as:

- `product_blocker`: product behavior, safety, privacy or data integrity is wrong;
- `verification_blocker`: the claim cannot yet be proven;
- `release_blocker`: product work may finish but publication is closed;
- `service_warning`: internal metadata can be reconciled automatically;
- `cosmetic`: does not affect the current work item.

Rules:

- product blockers route to repair;
- verification blockers route to audit;
- release blockers block RELEASE only;
- service warnings never require owner intervention and never create a new task pack;
- stale prose, test-count wording, evidence-sidecar drift and optional reports are service warnings when an authoritative current result exists;
- actual artifact inconsistency, unsafe wording, privacy failure and data corruption remain product blockers.
