# Companion control tooling

`companion-control.cjs` provides deterministic validation for Companion Pack 1.2.4:

```text
validate-pack
canonical-hash
validate-contract
validate-result
route
```

PowerShell wrappers are under `scripts/windows/companion/`.

These tools do not migrate active projects automatically. They validate the current command inventory, freeze a phase contract, enforce a repair budget, create a fail-closed phase result and test output isolation.

Runtime 1.2.3 also validates autonomous convergence contracts through `autonomous-convergence.cjs` and `tests/acceptance/autonomous-convergence-contract.cjs`.
