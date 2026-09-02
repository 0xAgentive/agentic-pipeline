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

## Fast-Feedback & Targeted Verification Contract

1. **Tier-1 Laser Verification First**:
   - For all incremental edits, execute ONLY the single targeted test file directly covering the modified component (e.g. `npx vitest run tests/hrv.test.ts` or `python -m unittest tests.test_unit`).
   - Limit stdout to max 10 lines of focused summary.
   - Do NOT run full multi-suite test runs or package builds during iterative development loops.
2. **Tier-2 Comprehensive Gate**:
   - Run full regression/integration suite (`npm test`, `Test-DistributionIntegrity.ps1`, `pytest`) ONLY ONCE upon phase completion or before final task closure.

## Universal Anti-Hang & Execution Watchdog Policy

1. **Focused verification first**: During iterative development, NEVER run full test or package suites for single-file changes. Run ONLY the focused test file (`npm run test:focused` / `pytest tests/test_focused.py`).
2. **Hard process ceiling on ALL tasks**:
   - Tests: max **120s** per run, **5s** per individual test (`--testTimeout=5000 --bail=5`).
   - Builds & packaging (`package.ps1`, `build.ps1`, `electron-builder`): max **180s** (ceiling **300s**).
   - All long-running commands MUST run through `scripts/Invoke-WithTimeout.ps1` with closed `stdin` and `CI=true`.
3. **Zero unconstrained background tasks**:
   - If a command is launched as a background task, the agent MUST schedule a watchdog wakeup using `schedule(DurationSeconds=180, TimerCondition="<task_id>")`.
   - If the task does not finish within 180s, the timer wakes up the agent, which terminates the hung task (`manage_task(Action='kill')`) and diagnoses the root cause immediately without waiting for user intervention.
4. **Strict non-interactive mode**:
   - All commands must run with `CI=true`, `GIT_TERMINAL_PROMPT=0`, `DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER=1`, `PIP_NO_INPUT=1`, and `NPM_CONFIG_YES=true`.
   - Interactive stdin prompts are prohibited in automation scripts.
5. **Zero-hang guarantee**: If any process exceeds its watchdog ceiling, the process tree is forcefully terminated (`taskkill /F /T`) and reported as a hard blocker.
