---
description: Final evidence-based SHIP or NO-SHIP decision. No implementation.
---

# /shipcheck

## Mode

Read-only final gate. Do not fix findings here.

## Required inputs

- `.agy/PHASE_STATUS.json`
- `.agy/PRODUCT_CONTRACT.json`
- `.agy/REQUIREMENTS_DELTA.md`
- `.agy/evidence.ndjson` and/or `.agy/EVIDENCE_LOG.md`
- `.agy/ARTIFACT_INDEX.ndjson` when artifacts are required
- test/build/lint/parser outputs
- visual/report/security evidence where applicable
- rollback notes

## Decision

Return `SHIP` only when requirements, state, checks, artifacts and gates agree.

Return `NO-SHIP` or `BLOCKED` when evidence is absent, requirements drift is unresolved, checks fail, UI/report/security blockers remain, or readiness relies on model prose.

## Output

Decision, evidence table, blockers, accepted residual risks, rollback and next command.

Stop after the decision.
