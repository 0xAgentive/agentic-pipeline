# Evidence Levels and Blocker Policy

Evidence intensity is selected before implementation and is proportional to risk.

## Evidence levels

### E0 — scratch

One-off exploration. No persistent evidence required beyond the result.

### E1 — lite

Small low-risk patch:

- diff;
- targeted check;
- brief result;
- no full archive unless the artifact itself is the deliverable.

### E2 — standard

Normal development or research:

- changed files;
- commands and exit codes;
- key outputs;
- targeted artifacts;
- current state and next action.

### E3 — critical

Privacy, health-adjacent methodology, migration, security or release candidate:

- deterministic logs;
- provenance;
- material artifact manifest;
- required QA gates;
- independent/read-only review;
- rollback evidence.

### E4 — archival

Publication or reproducible regulated/long-lived research:

- immutable package;
- full manifests and hashes;
- signed or external attestations where available;
- replay instructions;
- long-term provenance.

## Blocker taxonomy

- safety blocker;
- security/privacy blocker;
- data-integrity blocker;
- research-validity blocker;
- reproducibility blocker;
- delivery defect;
- observability defect;
- cosmetic debt.

## Risk-track policy

Research normally blocks on safety, data integrity and research validity. Delivery polish is non-blocking unless it compromises the chosen evidence level.

Public release blocks on safety, privacy, data integrity, required reproducibility and delivery integrity.

Do not classify every artifact mismatch as a product blocker. Record its effect on the current phase contract.
