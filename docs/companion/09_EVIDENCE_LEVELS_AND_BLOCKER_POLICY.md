# Assurance Modes and Blocker Materiality

## FLOW

Ordinary product work. Targeted checks and one run result. No independent audit by default.

## GUARDED

Privacy, exports, data integrity, security, health-adjacent wording or packaged behavior. Product-specific validators and one independent audit.

## RELEASE

Publication, migration, installer/distribution identity and release provenance. Full release gates may require manifests and hashes.

## Materiality

- `product_blocker`: product behavior, safety, privacy or data integrity is wrong;
- `verification_blocker`: the claim is not yet proven;
- `release_blocker`: release is closed while product work may finish;
- `service_warning`: internal metadata is auto-reconciled;
- `cosmetic`: no effect on current acceptance.

A stale sidecar, old test-count prose or rebuilt internal evidence archive is a service warning when an authoritative current result exists. Actual product ZIP/member inconsistency remains a product blocker.
