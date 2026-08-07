[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [string]$OutputRoot = '',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Version = Get-Content -LiteralPath (Join-Path $Root 'VERSION.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$Version.ecosystem_version -ne '1.2.8' -or [string]$Version.package_version -ne '1.2.8' -or [string]$Version.runtime_version -ne '1.2.8') {
  throw "Runtime overlay requires unified ecosystem 1.2.8."
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $Root '.artifacts\runtime\1.2.8'
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$ZipPath = Join-Path $OutputRoot 'agentic-project-runtime-1.2.8.zip'
if ((Test-Path -LiteralPath $ZipPath -PathType Leaf) -and -not $Force) {
  throw "Output exists. Use -Force: $ZipPath"
}

$Files = @(
  'VERSION.json',
  'ECOSYSTEM_VERSION.json',
  'config\command-inventory.json',
  'scripts\windows\Update-AgenticProjectRuntime-v1.2.8.ps1',
  'scripts\windows\Test-CommandInventory.ps1',
  'scripts\windows\Test-OwnerAutonomyContracts.ps1',
  'scripts\windows\Test-KnownFailureRegressionPlaybook-v1.2.8.ps1',
  'tests\regression\known-failure-regression.cjs',
  'tests\regression\KNOWN_FAILURE_PLAYBOOK_v1.2.8.json',
  'scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1',
  'scripts\control-plane\write-installation-manifest.cjs',
  'scripts\control-plane\autonomous-convergence.cjs',
  'scripts\control-plane\resolve-runtime-route.cjs',
  'scripts\control-plane\progress-guard.cjs',
  'scripts\control-plane\validate-findings.cjs',
  'scripts\control-plane\validate-owner-summary.cjs',
  'scripts\control-plane\action-packet.cjs',
  'tests\acceptance\autonomous-convergence-contract.cjs',
  'templates\agy-project-base\.agents\AGENTS.md',
  'templates\agy-project-base\.agents\COMMAND_INVENTORY.json',
  'templates\agy-project-base\.agents\hooks.json',
  'templates\agy-project-base\.agents\hooks\agentic_runtime_hook.cjs',
  'templates\agy-project-base\.agents\hooks\guard_preflight.ps1',
  'templates\agy-project-base\.agents\hooks\Test-HookContract.ps1',
  'templates\agy-project-base\.agents\rules\05-runtime-contract.md',
  'templates\agy-project-base\.agents\rules\10-pipeline-rules.md',
  'templates\agy-project-base\.agents\rules\30-product-evidence-contract.md',
  'templates\agy-project-base\.agents\rules\30-verification-gates.md',
  'templates\agy-project-base\.agents\rules\60-v1.2-runtime-truth.md',
  'templates\agy-project-base\.agents\rules\61-autonomous-audit-convergence.md',
  'templates\agy-project-base\.agents\rules\62-protected-reviewer.md',
  'templates\agy-project-base\.agents\rules\63-scientific-stage-firewall.md',
  'templates\agy-project-base\.agents\rules\64-owner-autonomy.md',
  'templates\agy-project-base\.agents\workflows\planonly.md',
  'templates\agy-project-base\.agents\workflows\nextphase.md',
  'templates\agy-project-base\.agents\workflows\auditphase.md',
  'templates\agy-project-base\.agents\workflows\fixcritical.md',
  'templates\agy-project-base\.agents\skills\audit-coverage-matrix\SKILL.md',
  'templates\agy-project-base\.agents\skills\protected-reviewer\SKILL.md',
  'templates\agy-project-base\.agents\skills\scientific-stage-firewall\SKILL.md',
  'templates\agy-project-base\.agy\CONVERGENCE_POLICY.json',
  'templates\agy-project-base\.agy\PROGRESS_POLICY.json',
  'templates\agy-project-base\.agy\PROGRESS_STATE.json',
  'templates\agy-project-base\.agy\NEXT_ACTION.json',
  'templates\agy-project-base\.agy\CANDIDATE_MANIFEST_STATUS.json',
  'templates\agy-project-base\.agy\STAGE_FIREWALL.json',
  'templates\agy-project-base\scripts\control-plane\autonomous-convergence.cjs',
  'templates\agy-project-base\scripts\control-plane\progress-guard.cjs',
  'templates\agy-project-base\scripts\control-plane\validate-findings.cjs',
  'templates\agy-project-base\scripts\control-plane\validate-owner-summary.cjs',
  'templates\agy-project-base\scripts\control-plane\action-packet.cjs',
  'templates\agy-project-base\scripts\windows\companion\New-WorkItem.ps1',
  'templates\agy-project-base\scripts\windows\companion\Set-WorkItemStatus.ps1',
  'templates\agy-project-base\scripts\windows\companion\Write-ExecutionScope.ps1',
  'templates\agy-project-base\scripts\windows\companion\Publish-RunResult.ps1',
  'templates\agy-project-base\scripts\windows\companion\New-ExecutionLease.ps1',
  'templates\agy-project-base\scripts\windows\companion\Test-ExecutionLease.ps1',
  'templates\agy-project-base\scripts\windows\companion\Publish-AuditCoverageMatrix.ps1',
  'templates\agy-project-base\scripts\windows\companion\Test-AuditCoverageMatrix.ps1',
  'templates\agy-project-base\scripts\windows\companion\Register-FindingDelta.ps1',
  'templates\agy-project-base\scripts\windows\companion\Publish-RepairDelta.ps1',
  'templates\agy-project-base\scripts\windows\companion\Register-RepairBatch.ps1',
  'templates\agy-project-base\scripts\windows\companion\New-ProtectedReviewerAttestation.ps1',
  'templates\agy-project-base\scripts\windows\companion\Test-ProtectedReviewerAttestation.ps1',
  'templates\agy-project-base\scripts\windows\companion\New-StageFirewall.ps1',
  'templates\agy-project-base\scripts\windows\companion\Compile-ResultAuthority.ps1',
  'templates\agy-project-base\scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1',
  'templates\agy-project-base\scripts\windows\companion\Activate-ActionPacket.ps1',
  'templates\agy-project-base\scripts\windows\companion\Start-WorkItemTransaction.ps1',
  'templates\agy-project-base\scripts\windows\companion\Bind-ExecutionScopeTransaction.ps1',
  'templates\agy-project-base\scripts\windows\companion\Register-Progress.ps1',
  'templates\agy-project-base\scripts\windows\companion\Test-FindingSet.ps1',
  'templates\agy-project-base\scripts\windows\companion\Validate-ControlPlaneState.ps1',
  'templates\agy-project-base\scripts\windows\companion\Publish-NextAction.ps1',
  'templates\agy-project-base\scripts\windows\companion\Publish-CandidateManifest.ps1',
  'templates\agy-project-base\scripts\windows\companion\Migrate-ActiveWorkItemToProgressGuard.ps1',
  'scripts\bridge\companion_action_bridge.py',
  'scripts\bridge\Install-CompanionActionBridge.ps1',
  'scripts\bridge\Import-CompanionActionPacket.ps1',
  'scripts\bridge\Run-CompanionActionBridgeWorker.ps1',
  'scripts\bridge\Uninstall-CompanionActionBridge.ps1'
)

$Temp = Join-Path $env:TEMP ('agentic-runtime-overlay-' + [Guid]::NewGuid().ToString('N'))
$PackageRoot = Join-Path $Temp 'agentic-project-runtime-1.2.8'
New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null
try {
  $Entries = New-Object System.Collections.Generic.List[object]
  foreach ($Relative in $Files) {
    $Source = Join-Path $Root $Relative
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Runtime overlay source missing: $Relative" }
    $Destination = Join-Path $PackageRoot $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $Info = Get-Item -LiteralPath $Destination
    [void]$Entries.Add([ordered]@{
      path = $Relative.Replace('\\','/')
      size_bytes = [int64]$Info.Length
      sha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    })
  }
  $Readme = @'
# Agentic Project Runtime 1.2.8 Overlay

Use `scripts/windows/Update-AgenticProjectRuntime-v1.2.8.ps1` first without `-Apply`, then with `-Apply -AllowDirty` after review. The updater changes only the explicit framework-owned allowlist, creates backups, never cleans/reset product source, migrates legacy counter-based routing to progress history, and activates project-local Antigravity hooks.
'@
  [IO.File]::WriteAllText((Join-Path $PackageRoot 'README_RU.md'), $Readme, $Utf8NoBom)
  $Manifest = [ordered]@{
    schema_version = '1.2.8'
    package_version = '1.2.8'
    runtime_version = '1.2.8'
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    files = [object[]]$Entries.ToArray()
  }
  [IO.File]::WriteAllText((Join-Path $PackageRoot 'RUNTIME_OVERLAY_MANIFEST.json'), ($Manifest | ConvertTo-Json -Depth 20), $Utf8NoBom)
  Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($PackageRoot, $ZipPath, [IO.Compression.CompressionLevel]::Optimal, $true)
  Write-Host "Runtime overlay built: $ZipPath"
  Write-Host "SHA-256: $((Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant())"
}
finally {
  Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
