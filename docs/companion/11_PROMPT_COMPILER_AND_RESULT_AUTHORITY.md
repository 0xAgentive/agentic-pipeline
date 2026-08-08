# Prompt Compiler and Single Result Authority

The Companion compiles one short immutable work brief. It does not invent runtime facts or exact paths.

After the initial brief, the machine authority is project-local:

- `EXECUTION_LEASE.json` for write authorization;
- `AUDIT_COVERAGE_MATRIX.json` for audit completeness;
- `FINDINGS.json` and `REPAIR_DELTA.json` for repairs;
- `REVIEWER_ATTESTATION.json` for protected audit independence;
- `RUN_RESULT.json` and `CLOSURE_STATE.json` for closure.

`Compile-ResultAuthority.ps1` is the only supported closure compiler for runtime 1.2.11. Do not independently hand-author contradictory run, audit, handshake and closure statuses.

If protected audit is unavailable after deterministic verification passes, close with verification debt and keep release blocked. Do not start another pseudo-independent audit loop.
