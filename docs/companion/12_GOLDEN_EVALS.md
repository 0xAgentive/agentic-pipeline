# Golden Evals v1.2.3

The active companion policy is tested against legacy routing failures and Flow Restoration failures.

Legacy cases remain byte-frozen under `evals/companion/golden_cases.json`. Flow Restoration cases live under `evals/companion/flow_restoration_cases.json`.

Required Flow Restoration cases include:

1. a new owner work item reopens product execution after an earlier SHIP;
2. shadow mode reports a candidate route but authorizes no write;
3. product blockers route to `/fixcritical`;
4. verification blockers route to `/auditphase`;
5. service warnings do not block product execution;
6. release commands remain closed during degraded product execution;
7. branch, project-root and execution-scope drift invalidate the lease;
8. repeated no-progress failure requires one owner hard-stop decision;
9. Companion briefs without source authority cannot claim exact paths;
10. evidence budgets remain proportional to FLOW, GUARDED and RELEASE.

Run both suites with:

```text
node scripts/companion/companion-control.cjs validate-pack --repo-root .
node scripts/companion/companion-control.cjs test-flow-restoration --repo-root .
```
