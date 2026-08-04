---
description: Comprehensive read-only audit with coverage matrix, stable findings and protected final review.
---

# /auditphase

Read-only. Do not repair in this workflow.

## Initial comprehensive audit

1. Bind exact work item, target root, branch and HEAD.
2. Publish `AUDIT_COVERAGE_MATRIX.json` mapping every acceptance outcome to surfaces, evidence and checks.
3. Reject incomplete acceptance coverage.
4. Inspect actual product artifacts and project-specific validators.
5. Publish all material findings with stable IDs in `FINDINGS.json`.
6. Register the single initial audit in `REPAIR_BUDGET.json`.

The first audit must aim for complete coverage before any repair batch.

## Final protected audit

1. Use a separate read-only reviewer root/context.
2. Bind exact final HEAD and exact artifact manifest.
3. Publish and validate `REVIEWER_ATTESTATION.json`.
4. Re-check the original coverage matrix and every finding lifecycle.
5. A new material finding is `audit_coverage_miss`.

If protected reviewer capability is unavailable, do not fabricate audit acceptance. Return audit unavailable for closure with verification debt.
