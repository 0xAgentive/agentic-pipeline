# Product Evidence Control Plane

The control plane prevents false readiness while remaining proportional to the current assurance mode. It must not turn ordinary product iteration into release engineering.

## Active contracts

### Work Item

The owner-approved goal, assurance mode, acceptance outcomes and non-goals. `SHIP` closes this work item; only `ARCHIVE` closes the project.

### Execution Scope

Antigravity creates the exact local path scope after read-only discovery. The Companion does not guess paths without live source authority.

### Run Result

The compact machine result for implementation, verification, audit, blockers, warnings and the next workflow. Latest successful deterministic results supersede stale prose.

### Assurance profiles

- FLOW: `WORK_ITEM.json` and `RUN_RESULT.json`; targeted verification; no independent audit by default.
- GUARDED: run result plus one protected audit and actual product artifacts.
- RELEASE: provenance, manifests, hashes, package extraction and release audit as required.

Hashes remain internal unless release identity, unresolved corruption or exact candidate disambiguation requires them.

## Finding materiality

- product blocker: actual user behavior/data is wrong; repair through `/fixcritical`;
- verification blocker: behavior may be correct but is not proven; route to `/auditphase`;
- release blocker: product work may complete but publication stays closed;
- service warning: deterministic metadata reconciliation; never owner-mediated;
- cosmetic: does not block the current work item.

## QA gates

Use only when the current risk requires them:

- visual/report checks for user-visible outputs;
- privacy/security checks for sensitive exports;
- protected verifier for GUARDED and RELEASE;
- scientific validation only for scientific claims.

## Release rule

`/shipcheck`, `/githubprepare` and `/githubsync` remain closed outside RELEASE readiness. Degraded product execution may continue bounded FLOW/GUARDED work, but never authorizes publication, migration or destructive operations.
