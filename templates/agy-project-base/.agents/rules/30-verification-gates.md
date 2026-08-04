# Verification Gates — Materiality and Convergence

Materiality:

- `product_blocker`: product behavior, safety, privacy or data integrity is wrong;
- `verification_blocker`: the current claim is not proven;
- `release_blocker`: release is closed but product work may finish;
- `service_warning`: metadata can be reconciled automatically;
- `cosmetic`: no material effect.

Lifecycle:

- first comprehensive audit publishes the material finding set;
- late material findings are `audit_coverage_miss`;
- current-scope product blockers route to grouped repair;
- verification limitations after deterministic pass may close with debt;
- release blockers do not freeze future owner-approved work;
- no more than the configured repair-batch budget without closure or one hard stop.
