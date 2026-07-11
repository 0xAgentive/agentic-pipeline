# Golden Evals v1.2.2

The companion policy is tested against real failure patterns observed across research and sensitive-data project dialogues.

Required cases:

1. unknown slash command is rejected;
2. runtime inventory controls routing;
3. phase contract cannot expand after execution;
4. second repair cycle requires a human decision;
5. research track ignores delivery-only debt unless validity is affected;
6. required child failure cannot produce success;
7. tests cannot modify production outputs;
8. stale artifact metadata invalidates only the affected claim;
9. final response uses machine-readable phase result;
10. environment version uses compatibility evidence unless exact version is contractual;
11. resolved findings are not counted as open;
12. implementation alignment does not equal scientific validation;
13. provenance mismatch blocks provenance claims but not identical market-content claims;
14. self-referential archive hash is rejected;
15. state-only recovery routes to `/landing`;
16. confirmed blockers route to `/fixcritical` only after audit.

The deterministic policy evals live under `evals/companion/golden_cases.json` and are run by the companion validator.
