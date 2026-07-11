# Product Evidence Control Plane

The control plane prevents false readiness. It must be proportionate to risk; it must not turn every local experiment into archival release engineering.

A project is not ready because an agent says it is ready. Readiness exists only when the current product goal, phase contract, implementation, checks, artifacts and required gates agree.

## Core contracts

### Product Contract

What is being built now, for whom, and what counts as done.

### Requirement Drift

A substantial goal change updates contract, plan and checks before implementation continues.

### Phase Contract

The current phase has frozen acceptance criteria and a contract hash. Post-execution findings are classified rather than appended silently.

### Artifact Delivery

Material artifacts must be inspectable. Required metadata depends on evidence level:

- E0/E1: path and targeted proof may be enough;
- E2: path, command result and key content/metadata;
- E3/E4: manifest, size, SHA-256, provenance and independent validation.

Do not require SHA-256 for every temporary markdown file when it does not affect validity, safety or release reproducibility.

### QA gates

Use only when applicable:

- VisualQA for UI;
- ReportQA for generated PDF/HTML/ZIP/CSV;
- SecurityQA for local data, secrets, exports and permissions;
- ArtifactAudit for required deliverables;
- domain validation for scientific or health-adjacent claims.

## Shipcheck rule

`/shipcheck` returns `SHIP` or `NO-SHIP` only when the runtime provides a deterministic shipcheck implementation.

It returns `NO-SHIP` if:

- required checks fail or are missing;
- a safety, privacy, data-integrity or release blocker is open;
- required material artifacts are missing;
- unresolved blocking requirement drift remains;
- mandatory gates are absent or stale;
- Product Contract and implemented behavior disagree;
- model prose is the only evidence.

Delivery-only defects do not automatically block research progress unless they compromise data integrity, reproducibility at the chosen evidence level, or the current phase contract.
