# Companion control tooling

`companion-control.cjs` provides deterministic validation for Companion Pack 1.2.2:

```text
validate-pack
canonical-hash
validate-contract
validate-result
route
```

PowerShell wrappers are under `scripts/windows/companion/`.

These tools do not migrate active projects automatically. They validate the current command inventory, freeze a phase contract, enforce a repair budget, create a fail-closed phase result and test output isolation.
