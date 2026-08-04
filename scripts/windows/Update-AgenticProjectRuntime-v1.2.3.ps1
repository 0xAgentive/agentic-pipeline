[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [switch]$Apply,
  [switch]$AllowDirty,
  [switch]$SkipValidation
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Pipeline = (Resolve-Path -LiteralPath $RepoRoot).Path
$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Template = Join-Path $Pipeline 'templates\agy-project-base'
$Version = Get-Content -LiteralPath (Join-Path $Pipeline 'VERSION.json') -Raw | ConvertFrom-Json

if ([string]($Version.package_version) -ne '1.2.6' -or [string]($Version.runtime_version) -ne '1.2.3') {
  throw "This updater requires Agentic Pipeline 1.2.6 / runtime 1.2.3. Found package=$($Version.package_version) runtime=$($Version.runtime_version)."
}
if (!(Test-Path -LiteralPath $Template -PathType Container)) { throw "Runtime template missing: $Template" }

$GitApplicable = $false
if (Test-Path -LiteralPath (Join-Path $Project '.git')) {
  $GitApplicable = $true
  $Status = @(& git -C $Project status --porcelain=v1 --untracked-files=all 2>&1)
  if ($LASTEXITCODE -ne 0) { throw 'git status failed for target project.' }
  if ($Status.Count -gt 0 -and !$AllowDirty) {
    Write-Host 'Project has pre-existing changes:'
    $Status | ForEach-Object { Write-Host $_ }
    throw 'Use -AllowDirty only after reviewing the exact runtime-owned allowlist. Product files are never cleaned or reset.'
  }
}

$FrameworkOwned = @(
  '.agents\AGENTS.md',
  '.agents\COMMAND_INVENTORY.json',
  '.agents\hooks\guard_preflight.ps1',
  '.agents\hooks\Test-HookContract.ps1',
  '.agents\rules\05-runtime-contract.md',
  '.agents\rules\10-pipeline-rules.md',
  '.agents\rules\30-product-evidence-contract.md',
  '.agents\rules\30-verification-gates.md',
  '.agents\rules\60-v1.2-runtime-truth.md',
  '.agents\rules\61-autonomous-audit-convergence.md',
  '.agents\rules\62-protected-reviewer.md',
  '.agents\rules\63-scientific-stage-firewall.md',
  '.agents\workflows\planonly.md',
  '.agents\workflows\nextphase.md',
  '.agents\workflows\auditphase.md',
  '.agents\workflows\fixcritical.md',
  '.agents\skills\audit-coverage-matrix\SKILL.md',
  '.agents\skills\protected-reviewer\SKILL.md',
  '.agents\skills\scientific-stage-firewall\SKILL.md',
  'scripts\control-plane\autonomous-convergence.cjs',
  'scripts\windows\companion\New-WorkItem.ps1',
  'scripts\windows\companion\Set-WorkItemStatus.ps1',
  'scripts\windows\companion\Write-ExecutionScope.ps1',
  'scripts\windows\companion\Publish-RunResult.ps1',
  'scripts\windows\companion\New-ExecutionLease.ps1',
  'scripts\windows\companion\Test-ExecutionLease.ps1',
  'scripts\windows\companion\Publish-AuditCoverageMatrix.ps1',
  'scripts\windows\companion\Test-AuditCoverageMatrix.ps1',
  'scripts\windows\companion\Register-FindingDelta.ps1',
  'scripts\windows\companion\Publish-RepairDelta.ps1',
  'scripts\windows\companion\Register-RepairBatch.ps1',
  'scripts\windows\companion\New-ProtectedReviewerAttestation.ps1',
  'scripts\windows\companion\Test-ProtectedReviewerAttestation.ps1',
  'scripts\windows\companion\New-StageFirewall.ps1',
  'scripts\windows\companion\Compile-ResultAuthority.ps1',
  'scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1'
)
$StateDefaults = @(
  '.agy\CONVERGENCE_POLICY.json',
  '.agy\STAGE_FIREWALL.json'
)

foreach ($Relative in $FrameworkOwned + $StateDefaults) {
  $Source = Join-Path $Template $Relative
  if (!(Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Runtime source missing: $Relative" }
}

$BackupRoot = Join-Path $Project ('.pipeline_runtime_update_backup\' + $Stamp)
$Copied = New-Object System.Collections.Generic.List[string]
$BackedUp = New-Object System.Collections.Generic.List[string]
$Skipped = New-Object System.Collections.Generic.List[string]

Write-Host "Agentic project runtime update"
Write-Host "Project: $Project"
Write-Host "Source: $Pipeline"
Write-Host "Package/runtime: $($Version.package_version) / $($Version.runtime_version)"
Write-Host "Apply: $Apply"
Write-Host 'Framework-owned paths:'
$FrameworkOwned | ForEach-Object { Write-Host "- $_" }
Write-Host 'State defaults (create only when missing):'
$StateDefaults | ForEach-Object { Write-Host "- $_" }

if (!$Apply) {
  Write-Host 'DRY RUN COMPLETE. No files changed. Add -Apply after review.'
  return
}

foreach ($Relative in $FrameworkOwned) {
  $Source = Join-Path $Template $Relative
  $Destination = Join-Path $Project $Relative
  if (Test-Path -LiteralPath $Destination -PathType Leaf) {
    $Backup = Join-Path $BackupRoot $Relative
    New-Item -ItemType Directory -Force (Split-Path -Parent $Backup) | Out-Null
    Copy-Item -LiteralPath $Destination -Destination $Backup -Force
    [void]$BackedUp.Add($Relative)
  }
  New-Item -ItemType Directory -Force (Split-Path -Parent $Destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
  [void]$Copied.Add($Relative)
}

foreach ($Relative in $StateDefaults) {
  $Source = Join-Path $Template $Relative
  $Destination = Join-Path $Project $Relative
  if (Test-Path -LiteralPath $Destination -PathType Leaf) {
    [void]$Skipped.Add($Relative)
    continue
  }
  New-Item -ItemType Directory -Force (Split-Path -Parent $Destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
  [void]$Copied.Add($Relative)
}

$ManifestWriter = Join-Path $Pipeline 'scripts\control-plane\write-installation-manifest.cjs'
$ManifestPath = Join-Path $Project '.agy\INSTALLATION_MANIFEST.json'
$Commit = 'unknown'
if (Test-Path -LiteralPath (Join-Path $Pipeline '.git')) {
  $CommitText = @(& git -C $Pipeline rev-parse HEAD 2>&1)
  if ($LASTEXITCODE -eq 0) { $Commit = ($CommitText -join "`n").Trim() }
}
$Metadata = [ordered]@{
  installed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  mode = 'runtime-update'
  state_profile = 'preserved'
  source_repo = 'agentic-pipeline'
  source_commit = $Commit
  conflict_policy = 'framework-owned-overlay'
  copied = $Copied.ToArray()
  skipped = $Skipped.ToArray()
  backed_up = $BackedUp.ToArray()
  backup_root = if ($BackedUp.Count -gt 0) { $BackupRoot } else { $null }
  next_command = $null
}
$MetadataPath = Join-Path ([IO.Path]::GetTempPath()) ('agentic-runtime-update-' + [guid]::NewGuid().ToString('N') + '.json')
[IO.File]::WriteAllText($MetadataPath, ($Metadata | ConvertTo-Json -Depth 30), $Utf8NoBom)
try {
  & node $ManifestWriter --repo-root $Pipeline --output $ManifestPath --metadata-file $MetadataPath
  if ($LASTEXITCODE -ne 0) { throw 'Installation manifest writer failed.' }
}
finally { Remove-Item -LiteralPath $MetadataPath -Force -ErrorAction SilentlyContinue }

if (!$SkipValidation) {
  & (Join-Path $Pipeline 'scripts\windows\Test-CommandInventory.ps1') -RepoRoot $Pipeline -ProjectRoot $Project
  if ($LASTEXITCODE -ne 0) { throw 'Deployed command inventory validation failed.' }
  & (Join-Path $Project 'scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1') -RepoRoot $Pipeline
  if ($LASTEXITCODE -ne 0) { throw 'Autonomous convergence validation failed.' }
  & (Join-Path $Project '.agents\hooks\Test-HookContract.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'Project hook contract failed.' }
}

$Result = [ordered]@{
  schema_version = '1.0.0'
  status = 'PASS'
  project_root = $Project
  package_version = [string]($Version.package_version)
  runtime_version = [string]($Version.runtime_version)
  copied = $Copied.ToArray()
  skipped = $Skipped.ToArray()
  backed_up = $BackedUp.ToArray()
  backup_root = if ($BackedUp.Count -gt 0) { $BackupRoot } else { $null }
  product_source_modified = $false
  generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
}
$ResultPath = Join-Path $Project '.agy\RUNTIME_UPDATE_RESULT.json'
[IO.File]::WriteAllText($ResultPath, ($Result | ConvertTo-Json -Depth 30), $Utf8NoBom)
Write-Host "Runtime update completed: $Project"
Write-Host "Result: $ResultPath"
