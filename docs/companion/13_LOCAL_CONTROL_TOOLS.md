# Local Control Tools

The repository includes optional read-only or bounded local tools under `scripts/windows/companion/`. They are not ChatGPT knowledge and do not migrate active projects automatically.

- `Get-RuntimeHandshake.ps1`: inspect command inventory, roots and current state before routing.
- `New-PhaseContract.ps1`: create a dry-run or frozen phase contract.
- `Test-PhaseContract.ps1`: verify the contract hash and lock.
- `Register-RepairCycle.ps1`: enforce the repair budget.
- `New-PhaseResult.ps1`: produce a fail-closed machine-readable phase result.
- `Test-PhaseResult.ps1`: verify result/contract consistency.
- `Test-ProductionOutputIsolation.ps1`: run a test command with temporary roots and detect production additions, modifications or deletions.
- `Test-CompanionPack-v1.2.2.ps1`: validate policies, schemas and golden cases.
- `Build-CompanionPack-v1.2.2.ps1`: build the standalone ChatGPT Project knowledge pack.

Use tools only after reviewing their dry-run output. Active product migration remains a separate phase.
