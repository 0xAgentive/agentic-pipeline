# Local Control Tools

The repository includes bounded local tools under `scripts/windows/companion/`. They are not ChatGPT knowledge and do not migrate active projects automatically.

Flow Restoration tools:

- `New-WorkItem.ps1`: open a new owner-approved work item and increment `goal_epoch`.
- `Write-ExecutionScope.ps1`: write the executor-discovered exact scope.
- `Publish-RunResult.ps1`: publish compact product, verification, release and service-warning results.
- `Set-WorkItemStatus.ps1`: update one work item without closing the project.
- `Get-RuntimeHandshake.ps1`: resolve current and shadow routes.
- `Test-FlowRestorationContracts.ps1`: exercise shadow, enforcing, repair, audit and work-item reopening behavior.
- `Test-CompanionPack-v1.2.3.ps1`: validate active Companion and routing policies.
- `Build-CompanionPack-v1.2.3.ps1`: build the Companion pack.

Legacy phase-contract tools remain available for RELEASE or migrated projects:

- `New-PhaseContract.ps1`;
- `Test-PhaseContract.ps1`;
- `Register-RepairCycle.ps1`;
- `New-PhaseResult.ps1`;
- `Test-PhaseResult.ps1`;
- `Test-ProductionOutputIsolation.ps1`.

Use dry-run output first. H10 rollout begins in shadow mode; enforcing migration remains a separate, reversible action.
