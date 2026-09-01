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

## Test Discipline and Timeout Enforcement

1. **Focused tests first**: During iterative development and bug fixing, NEVER run the full test suite for single-file changes. Run ONLY the focused test file relevant to the change (takes 1-3 seconds).
2. **Strict per-test timeout**: Every test runner invocation must enforce a per-test timeout (`--testTimeout=5000 --hookTimeout=5000`) and fail-fast (`--bail=1` during development, `--bail=5` during suite runs).
3. **Hard execution ceiling**: Full test suite runs must always execute via the watchdog script (`scripts/Invoke-TestWithTimeout.ps1` or `scripts/run_and_capture_verification.ps1`) with a maximum ceiling of 180 seconds.
4. **Zero-hang guarantee**: If a test suite exceeds the ceiling, the watchdog forcefully terminates the entire process tree to prevent agent lockup and 20-minute hangs.
