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

Before compiling closure, create a fresh verification receipt after the current candidate and every required test/evidence file. Each required test entry must contain `run_id`, `required`, `exit_code`, `completed_at_utc`, `evidence_path`, `evidence_sha256`, and `evidence_size_bytes`; `evidence_path` must be an exact portable, non-reparse path under `.agy/verification/**` and must not name capability, credential, secret, token, password or private-key material. The receipt must also bind `work_item_id`, `goal_epoch`, `branch`, `head`, `execution_lease_id`, `candidate_manifest_sha256`, `completed_at_utc`, `changed_files`, `evidence_artifacts`, and `product_artifacts`.

Run the compiler only through the inventory invocation template. Wait for its bounded completion result. On `-Apply`, trust closure only when `.agy/RUN_RESULT.json` contains the canonical `.agy/VERIFICATION_RECEIPT.json` path/hash/binding and `compiled_at_utc` at or after receipt completion. Do not read an older result while compilation is active, coalesced, timed out, or failed.

Stop after the decision.
