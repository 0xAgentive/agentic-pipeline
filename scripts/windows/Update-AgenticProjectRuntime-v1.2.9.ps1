[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ProjectRoot,
  [string]$RuntimeRoot = '',
  [string]$RepoRoot = '',
  [string]$RuntimeArchivePath = '',
  [string]$AssetSha256 = '',
  [switch]$Apply,
  [switch]$AllowDirty,
  [switch]$SkipValidation,
  [switch]$SkipActiveWorkItemMigration,
  [ValidateRange(0, 100000)][int]$FaultInjectionAfterWrites = 0,
  [switch]$FaultInjectionAfterMigration,
  [string]$BackupBaseRoot = "$env:USERPROFILE\Documents\antigravity\pipeline-maintenance\runtime-backups"
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$EcosystemVersion = '1.2.9'

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
  $RuntimeRoot = if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot } else { (Join-Path $PSScriptRoot '..\..') }
}
$SourceRoot = (Resolve-Path -LiteralPath $RuntimeRoot).Path
$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
. (Join-Path $SourceRoot 'scripts\windows\common\NativeProcess.ps1')

function Get-OptionalProperty([object]$Object, [string]$Name, [object]$Default = $null) {
  if ($null -eq $Object) { return $Default }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property) { return $Default }
  return $Property.Value
}

function Set-JsonProperty([object]$Object, [string]$Name, [object]$Value) {
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
  else { $Property.Value = $Value }
}

function Remove-JsonProperty([object]$Object, [string]$Name) {
  if ($null -ne $Object.PSObject.Properties[$Name]) { [void]$Object.PSObject.Properties.Remove($Name) }
}

function Write-BytesAtomic([string]$Path, [byte[]]$Bytes) {
  $Parent = Split-Path -Parent $Path
  if ($Parent) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
  $Temp = Join-Path $Parent ('.agentic-write-' + [Guid]::NewGuid().ToString('N'))
  try {
    [System.IO.File]::WriteAllBytes($Temp, $Bytes)
    Move-Item -LiteralPath $Temp -Destination $Path -Force
  }
  finally { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
}

function Write-JsonAtomic([string]$Path, [object]$Value, [int]$Depth = 50) {
  Write-BytesAtomic -Path $Path -Bytes $Utf8NoBom.GetBytes(($Value | ConvertTo-Json -Depth $Depth))
}

function Get-Sha256([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256([string]$Text) {
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try { return ([Convert]::ToHexString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).ToLowerInvariant() }
  finally { $Hasher.Dispose() }
}

function Normalize-Relative([string]$Relative) {
  $Value = $Relative.Replace('\', '/').Trim()
  while ($Value.StartsWith('./', [StringComparison]::Ordinal)) { $Value = $Value.Substring(2) }
  if ([string]::IsNullOrWhiteSpace($Value) -or [IO.Path]::IsPathRooted($Value) -or $Value.Contains(':') -or $Value -match '(^|/)\.\.(/|$)') {
    throw "Unsafe runtime target path: $Relative"
  }
  return $Value
}

function Resolve-ConfinedPath([string]$Root, [string]$Relative, [switch]$RejectReparseParents) {
  $Normalized = Normalize-Relative $Relative
  $RootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $Resolved = [IO.Path]::GetFullPath((Join-Path $RootFull $Normalized.Replace('/', '\')))
  if (-not $Resolved.StartsWith($RootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes root: $Relative" }
  if ($RejectReparseParents) {
    $Cursor = Split-Path -Parent $Resolved
    while ($Cursor.Length -ge $RootFull.Length -and $Cursor.StartsWith($RootFull, [StringComparison]::OrdinalIgnoreCase)) {
      if (Test-Path -LiteralPath $Cursor) {
        $Attributes = (Get-Item -LiteralPath $Cursor -Force).Attributes
        if (($Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point in runtime target path: $Cursor" }
      }
      if ($Cursor -eq $RootFull) { break }
      $Cursor = Split-Path -Parent $Cursor
    }
  }
  return $Resolved
}

function Invoke-Git([string[]]$Arguments) {
  $Result = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList (@('-c', 'core.quotepath=false', '-C', $Project) + $Arguments)
  Assert-AgenticNativeSuccess -Result $Result -Description 'git'
  return $Result
}

$VersionPath = Join-Path $SourceRoot 'VERSION.json'
if (-not (Test-Path -LiteralPath $VersionPath -PathType Leaf)) { throw "VERSION.json missing in runtime source: $SourceRoot" }
$Version = Get-Content -LiteralPath $VersionPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($Field in @('ecosystem_version', 'package_version', 'runtime_version', 'playbook_version', 'companion_version')) {
  if ([string](Get-OptionalProperty $Version $Field '') -ne $EcosystemVersion) { throw "Runtime source has inconsistent $Field." }
}
foreach ($CommandName in @('git', 'node', 'pwsh')) {
  if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) { throw "Required command missing: $CommandName" }
}

$ManifestPath = Join-Path $SourceRoot 'RUNTIME_OVERLAY_MANIFEST.json'
$OverlayManifest = if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) { Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$SourceCommit = [string](Get-OptionalProperty $OverlayManifest 'source_commit' '')
if ([string]::IsNullOrWhiteSpace($SourceCommit)) {
  $SourceGit = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C', $SourceRoot, 'rev-parse', 'HEAD')
  if ($SourceGit.ExitCode -eq 0) { $SourceCommit = $SourceGit.StdOut.Trim() }
}
if ($SourceCommit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Runtime source commit is missing or invalid.' }

if ($null -ne $OverlayManifest) {
  if ([string]::IsNullOrWhiteSpace($RuntimeArchivePath) -or -not (Test-Path -LiteralPath $RuntimeArchivePath -PathType Leaf)) { throw 'RuntimeArchivePath is required when installing an extracted release asset.' }
  $ArchiveFull = (Resolve-Path -LiteralPath $RuntimeArchivePath).Path
  $ActualAssetSha = (Get-FileHash -LiteralPath $ArchiveFull -Algorithm SHA256).Hash.ToLowerInvariant()
  if (-not [string]::IsNullOrWhiteSpace($AssetSha256) -and $AssetSha256.ToLowerInvariant() -ne $ActualAssetSha) { throw 'Runtime archive SHA-256 does not match AssetSha256.' }
  $AssetSha256 = $ActualAssetSha
  foreach ($Member in @((Get-OptionalProperty $OverlayManifest 'files' @()))) {
    $Relative = Normalize-Relative ([string]$Member.path)
    $MemberPath = Resolve-ConfinedPath -Root $SourceRoot -Relative $Relative
    if (-not (Test-Path -LiteralPath $MemberPath -PathType Leaf)) { throw "Runtime manifest member missing: $Relative" }
    if ((Get-Sha256 $MemberPath) -ne ([string]$Member.sha256).ToLowerInvariant() -or [int64](Get-Item -LiteralPath $MemberPath).Length -ne [int64]$Member.size_bytes) { throw "Runtime manifest member identity mismatch: $Relative" }
  }
}

$BaseReplaceTargets = @(
  '.agents/AGENTS.md','.agents/COMMAND_INVENTORY.json','.agents/hooks.json','.agents/hooks/agentic_runtime_hook.cjs','.agents/hooks/guard_preflight.ps1','.agents/hooks/Test-HookContract.ps1',
  '.agents/rules/05-runtime-contract.md','.agents/rules/10-pipeline-rules.md','.agents/rules/30-product-evidence-contract.md','.agents/rules/30-verification-gates.md','.agents/rules/60-v1.2-runtime-truth.md','.agents/rules/61-autonomous-audit-convergence.md','.agents/rules/62-protected-reviewer.md','.agents/rules/63-scientific-stage-firewall.md','.agents/rules/64-owner-autonomy.md',
  '.agents/skills/audit-coverage-matrix/SKILL.md','.agents/skills/protected-reviewer/SKILL.md','.agents/skills/scientific-stage-firewall/SKILL.md',
  'scripts/control-plane/autonomous-convergence.cjs','scripts/control-plane/progress-guard.cjs','scripts/control-plane/validate-findings.cjs','scripts/control-plane/validate-owner-summary.cjs','scripts/control-plane/action-packet.cjs',
  'scripts/windows/companion/New-WorkItem.ps1','scripts/windows/companion/Set-WorkItemStatus.ps1','scripts/windows/companion/Write-ExecutionScope.ps1','scripts/windows/companion/Publish-RunResult.ps1','scripts/windows/companion/New-ExecutionLease.ps1','scripts/windows/companion/Test-ExecutionLease.ps1','scripts/windows/companion/Publish-AuditCoverageMatrix.ps1','scripts/windows/companion/Test-AuditCoverageMatrix.ps1','scripts/windows/companion/Register-FindingDelta.ps1','scripts/windows/companion/Publish-RepairDelta.ps1','scripts/windows/companion/Register-RepairBatch.ps1','scripts/windows/companion/New-ProtectedReviewerAttestation.ps1','scripts/windows/companion/Test-ProtectedReviewerAttestation.ps1','scripts/windows/companion/New-StageFirewall.ps1','scripts/windows/companion/Compile-ResultAuthority.ps1','scripts/windows/companion/Test-AutonomousConvergenceContracts.ps1','scripts/windows/companion/Activate-ActionPacket.ps1','scripts/windows/companion/Start-WorkItemTransaction.ps1','scripts/windows/companion/Bind-ExecutionScopeTransaction.ps1','scripts/windows/companion/Register-Progress.ps1','scripts/windows/companion/Test-FindingSet.ps1','scripts/windows/companion/Validate-ControlPlaneState.ps1','scripts/windows/companion/Publish-NextAction.ps1','scripts/windows/companion/Publish-CandidateManifest.ps1','scripts/windows/companion/Migrate-ActiveWorkItemToProgressGuard.ps1',
  'scripts/windows/common/NativeProcess.ps1','scripts/Test-FastPatchAllowed.ps1','scripts/cbm-index-current-rpc.cjs','scripts/github/Prepare-GitHubPackage.ps1','scripts/github/Sync-GitHub.ps1'
)
$Inventory = Get-Content -LiteralPath (Join-Path $SourceRoot 'config\command-inventory.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$WorkflowTargets = @($Inventory.commands | ForEach-Object { Normalize-Relative ([string]$_.workflow) } | Sort-Object -Unique)
if ($WorkflowTargets.Count -ne 20 -or @($WorkflowTargets | Where-Object { $_ -notmatch '^\.agents/workflows/[a-z0-9-]+\.md$' }).Count -gt 0) { throw 'Runtime command inventory must declare exactly 20 confined workflow targets.' }
$StateTargets = @('.agy/CONVERGENCE_POLICY.json','.agy/PROGRESS_POLICY.json','.agy/PROGRESS_STATE.json','.agy/NEXT_ACTION.json','.agy/CANDIDATE_MANIFEST_STATUS.json','.agy/STAGE_FIREWALL.json','.agy/GITHUB_PROFILE.json')
$AllowedDeploymentTargets = @($BaseReplaceTargets + $WorkflowTargets + $StateTargets | Sort-Object -Unique)
if ($AllowedDeploymentTargets.Count -ne 79) { throw "Internal runtime allowlist is incomplete: $($AllowedDeploymentTargets.Count) targets." }
$DirectTargets = @('scripts/Test-FastPatchAllowed.ps1','scripts/cbm-index-current-rpc.cjs','scripts/github/Prepare-GitHubPackage.ps1','scripts/github/Sync-GitHub.ps1')
function Get-ExpectedSource([string]$Target) { if ($Target -in $DirectTargets) { return $Target }; return 'templates/agy-project-base/' + $Target }
function Get-ExpectedMode([string]$Target) { if ($Target -eq '.agents/hooks.json') { return 'activate_last' }; if ($Target -in @('.agy/CONVERGENCE_POLICY.json','.agy/PROGRESS_POLICY.json')) { return 'policy_replace' }; if ($Target.StartsWith('.agy/')) { return 'create_if_missing' }; return 'replace' }

$Map = New-Object System.Collections.Generic.List[object]
$ManifestMap = Get-OptionalProperty $OverlayManifest 'deployment_map'
if ($null -ne $ManifestMap) {
  foreach ($Item in @($ManifestMap)) { [void]$Map.Add($Item) }
}
else {
  foreach ($Target in $AllowedDeploymentTargets) {
    $SourceRelative = Get-ExpectedSource $Target
    $File = Resolve-ConfinedPath -Root $SourceRoot -Relative $SourceRelative
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Runtime allowlist source missing: $SourceRelative" }
    [void]$Map.Add([pscustomobject]@{ source = $SourceRelative; target = $Target; mode = Get-ExpectedMode $Target; sha256 = Get-Sha256 $File; size_bytes = [int64](Get-Item $File).Length })
  }
}
if ($Map.Count -ne $AllowedDeploymentTargets.Count) { throw "Runtime deployment map must contain exactly $($AllowedDeploymentTargets.Count) targets; found $($Map.Count)." }

$Seen = @{}
foreach ($Item in $Map) {
  $Item.source = Normalize-Relative ([string]$Item.source)
  $Item.target = Normalize-Relative ([string]$Item.target)
  if ($Item.target -notin $AllowedDeploymentTargets) { throw "Runtime manifest target is outside the exact framework allowlist: $($Item.target)" }
  $ExpectedSource = Get-ExpectedSource $Item.target
  $ExpectedMode = Get-ExpectedMode $Item.target
  if ($Item.source -cne $ExpectedSource -or [string]$Item.mode -cne $ExpectedMode) { throw "Runtime manifest mapping is not canonical: $($Item.source) -> $($Item.target) mode=$($Item.mode)" }
  $Key = $Item.target.ToLowerInvariant()
  if ($Seen.ContainsKey($Key)) { throw "Duplicate/colliding runtime target: $($Item.target)" }
  $Seen[$Key] = $true
  $Source = Resolve-ConfinedPath -Root $SourceRoot -Relative $Item.source
  $Target = Resolve-ConfinedPath -Root $Project -Relative $Item.target -RejectReparseParents
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Runtime member missing: $($Item.source)" }
  if ((Get-Sha256 $Source) -ne ([string]$Item.sha256).ToLowerInvariant()) { throw "Runtime member hash mismatch: $($Item.source)" }
  if ([int64](Get-Item -LiteralPath $Source).Length -ne [int64]$Item.size_bytes) { throw "Runtime member size mismatch: $($Item.source)" }
}

$ConditionalState = @(
  '.agy/WORK_ITEM.json', '.agy/WORK_ITEM_TRANSACTION.json', '.agy/EXECUTION_SCOPE.json', '.agy/EXECUTION_LEASE.json',
  '.agy/EXECUTION_AUTHORITY_TRANSACTION.json', '.agy/STAGE_FIREWALL.json', '.agy/RUNTIME_HANDSHAKE.json',
  '.agy/PROGRESS_STATE.json', '.agy/NEXT_ACTION.json', '.agy/OWNER_AUTONOMY_MIGRATION_RESULT.json',
  '.agy/CONVERGENCE_BUDGET.json', '.agy/REPAIR_BUDGET.json', '.agy/repair-ledger.ndjson',
  '.agy/history/legacy-repair-budget/runtime-1.2.9/CONVERGENCE_BUDGET.json',
  '.agy/history/legacy-repair-budget/runtime-1.2.9/REPAIR_BUDGET.json',
  '.agy/history/legacy-repair-budget/runtime-1.2.9/repair-ledger.ndjson',
  '.agy/INSTALLATION_MANIFEST.json', '.agy/RUNTIME_UPDATE_RESULT.json'
)
$FrameworkSet = @{}
foreach ($Path in @($Map.target) + $ConditionalState) { $FrameworkSet[(Normalize-Relative $Path).ToLowerInvariant()] = $true }

function Get-ProductSnapshot {
  $FilesResult = Invoke-Git @('ls-files', '-z', '--cached', '--others', '--exclude-standard')
  $Rows = New-Object System.Collections.Generic.List[object]
  foreach ($RawPath in (Split-AgenticNulList -Text $FilesResult.StdOut)) {
    $Relative = Normalize-Relative $RawPath
    if ($FrameworkSet.ContainsKey($Relative.ToLowerInvariant())) { continue }
    $Full = Resolve-ConfinedPath -Root $Project -Relative $Relative
    if (Test-Path -LiteralPath $Full -PathType Leaf) {
      $Item = Get-Item -LiteralPath $Full
      [void]$Rows.Add([pscustomobject]@{ path = $Relative; size_bytes = [int64]$Item.Length; sha256 = Get-Sha256 $Full })
    }
  }
  return @($Rows.ToArray() | Sort-Object path)
}

function Get-SnapshotIdentity([object[]]$Rows) {
  return Get-TextSha256 ((@($Rows | ForEach-Object { "$($_.path)`0$($_.size_bytes)`0$($_.sha256)" }) -join "`n"))
}

$StatusResult = Invoke-Git @('status', '--porcelain=v2', '-z', '--untracked-files=all')
if ($StatusResult.StdOut.Length -gt 0 -and -not $AllowDirty) { throw 'Target project is dirty. Use -AllowDirty only after reviewing the exact runtime deployment plan.' }
$ProductBefore = @(Get-ProductSnapshot)
$ProductBeforeIdentity = Get-SnapshotIdentity $ProductBefore

$Plan = New-Object System.Collections.Generic.List[object]
foreach ($Item in $Map) {
  $Source = Resolve-ConfinedPath -Root $SourceRoot -Relative $Item.source
  $Target = Resolve-ConfinedPath -Root $Project -Relative $Item.target -RejectReparseParents
  $CurrentHash = Get-Sha256 $Target
  $Action = if ($Item.mode -eq 'create_if_missing' -and $null -ne $CurrentHash) { 'preserve' } elseif ($CurrentHash -eq ([string]$Item.sha256).ToLowerInvariant()) { 'current' } else { if ($null -eq $CurrentHash) { 'create' } else { 'replace' } }
  [void]$Plan.Add([pscustomobject]@{ target = $Item.target; mode = $Item.mode; action = $Action; current_sha256 = $CurrentHash; incoming_sha256 = ([string]$Item.sha256).ToLowerInvariant() })
}

$MigrationResultPath = Join-Path $Project '.agy\OWNER_AUTONOMY_MIGRATION_RESULT.json'
$InstallationPath = Join-Path $Project '.agy\INSTALLATION_MANIFEST.json'
$RuntimeResultPath = Join-Path $Project '.agy\RUNTIME_UPDATE_RESULT.json'
$MigrationCurrent = $false
if (Test-Path -LiteralPath $MigrationResultPath -PathType Leaf) {
  try { $MigrationCurrent = [string](Get-Content -LiteralPath $MigrationResultPath -Raw -Encoding UTF8 | ConvertFrom-Json).ecosystem_version -eq $EcosystemVersion } catch { $MigrationCurrent = $false }
}
$ReceiptsCurrent = $false
if ((Test-Path -LiteralPath $InstallationPath -PathType Leaf) -and (Test-Path -LiteralPath $RuntimeResultPath -PathType Leaf)) {
  try {
    $Installed = Get-Content -LiteralPath $InstallationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $RuntimeResult = Get-Content -LiteralPath $RuntimeResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ReceiptsCurrent = [string]$Installed.package_version -eq $EcosystemVersion -and [string]$Installed.source_commit -eq $SourceCommit -and [string]$RuntimeResult.runtime_version -eq $EcosystemVersion -and [string]$RuntimeResult.source_commit -eq $SourceCommit
    if (-not [string]::IsNullOrWhiteSpace($AssetSha256)) { $ReceiptsCurrent = $ReceiptsCurrent -and [string]$Installed.release_asset_sha256 -eq $AssetSha256.ToLowerInvariant() }
  } catch { $ReceiptsCurrent = $false }
}
$AllFilesCurrent = @($Plan | Where-Object { $_.action -notin @('current', 'preserve') }).Count -eq 0
$AlreadyCurrent = $AllFilesCurrent -and ($SkipActiveWorkItemMigration -or $MigrationCurrent) -and $ReceiptsCurrent

$Summary = [ordered]@{ schema_version = '1.0.0'; ecosystem_version = $EcosystemVersion; source_commit = $SourceCommit; asset_sha256 = if ($AssetSha256) { $AssetSha256.ToLowerInvariant() } else { $null }; project_root = $Project; apply = [bool]$Apply; already_current = $AlreadyCurrent; product_baseline_sha256 = $ProductBeforeIdentity; plan = $Plan.ToArray() }
if (-not $Apply) { $Summary | ConvertTo-Json -Depth 20; Write-Host 'DRY RUN COMPLETE. No files changed.'; return }

function Invoke-DeployedValidation {
  if ($SkipValidation) { return }
  & (Join-Path $SourceRoot 'scripts\windows\Test-CommandInventory.ps1') -RepoRoot $SourceRoot -ProjectRoot $Project -SkipDocumentationScan
  if ($LASTEXITCODE -ne 0) { throw 'Deployed command inventory validation failed.' }
  & (Join-Path $Project 'scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1') -RepoRoot $SourceRoot
  if ($LASTEXITCODE -ne 0) { throw 'Autonomous convergence validation failed.' }
  if (Test-Path -LiteralPath (Join-Path $Project '.agy\WORK_ITEM.json') -PathType Leaf) {
    & (Join-Path $Project 'scripts\windows\companion\Validate-ControlPlaneState.ps1') -ProjectRoot $Project -RequireActiveLease
  }
  else {
    & (Join-Path $Project 'scripts\windows\companion\Validate-ControlPlaneState.ps1') -ProjectRoot $Project
  }
  if ($LASTEXITCODE -ne 0) { throw 'Control-plane authority validation failed.' }
  & (Join-Path $Project '.agents\hooks\Test-HookContract.ps1') -ProjectRoot $Project
  if ($LASTEXITCODE -ne 0) { throw 'Project hook contract failed.' }
}

if ($AlreadyCurrent) {
  Invoke-DeployedValidation
  $ProductAfter = @(Get-ProductSnapshot)
  if ((Get-SnapshotIdentity $ProductAfter) -ne $ProductBeforeIdentity) { throw 'Product baseline changed during verification-only updater run.' }
  Write-Host 'PROJECT RUNTIME 1.2.9 ALREADY CURRENT; VERIFICATION-ONLY RUN PASSED.' -ForegroundColor Green
  return
}

$ProjectSlug = ([IO.Path]::GetFileName($Project) -replace '[^A-Za-z0-9._-]', '_')
$TransactionId = 'runtime-1.2.9-' + [Guid]::NewGuid().ToString('N')
$BackupRoot = Join-Path ([IO.Path]::GetFullPath($BackupBaseRoot)) (Join-Path $ProjectSlug $TransactionId)
$LockRoot = Join-Path ([IO.Path]::GetFullPath($BackupBaseRoot)) '.locks'
New-Item -ItemType Directory -Force -Path $LockRoot | Out-Null
$LockPath = Join-Path $LockRoot ((Get-TextSha256 $Project).Substring(0, 24) + '.lock')
$LockStream = $null
$BackupIndex = New-Object System.Collections.Generic.List[object]
$MutationStarted = $false
$CreatedOrReplaced = New-Object System.Collections.Generic.List[string]
$Skipped = New-Object System.Collections.Generic.List[string]
$WriteCount = 0

function Backup-Path([string]$Relative) {
  $Normalized = Normalize-Relative $Relative
  if (@($BackupIndex | Where-Object { $_.relative -eq $Normalized }).Count -gt 0) { return }
  $Destination = Resolve-ConfinedPath -Root $Project -Relative $Normalized
  $Entry = [ordered]@{ relative = $Normalized; existed = (Test-Path -LiteralPath $Destination -PathType Leaf); sha256 = $null; backup = $null }
  if ($Entry.existed) {
    $Entry.sha256 = Get-Sha256 $Destination
    $Entry.backup = Join-Path $BackupRoot ('files\' + $Normalized.Replace('/', '\'))
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Entry.backup) | Out-Null
    Copy-Item -LiteralPath $Destination -Destination $Entry.backup -Force
  }
  [void]$BackupIndex.Add([pscustomobject]$Entry)
}

function Restore-Transaction {
  foreach ($Entry in @($BackupIndex.ToArray() | Sort-Object { $_.relative.Length } -Descending)) {
    $Destination = Resolve-ConfinedPath -Root $Project -Relative $Entry.relative
    if ($Entry.existed) { Write-BytesAtomic -Path $Destination -Bytes ([IO.File]::ReadAllBytes([string]$Entry.backup)) }
    elseif (Test-Path -LiteralPath $Destination -PathType Leaf) { Remove-Item -LiteralPath $Destination -Force }
  }
}

function Copy-MapItem([object]$Item) {
  $Source = Resolve-ConfinedPath -Root $SourceRoot -Relative ([string]$Item.source)
  $Target = Resolve-ConfinedPath -Root $Project -Relative ([string]$Item.target) -RejectReparseParents
  if ([string]$Item.mode -eq 'create_if_missing' -and (Test-Path -LiteralPath $Target -PathType Leaf)) { [void]$Skipped.Add([string]$Item.target); return }
  if ((Get-Sha256 $Target) -eq ([string]$Item.sha256).ToLowerInvariant()) { [void]$Skipped.Add([string]$Item.target); return }
  $script:MutationStarted = $true
  Write-BytesAtomic -Path $Target -Bytes ([IO.File]::ReadAllBytes($Source))
  $script:WriteCount++
  if ($FaultInjectionAfterWrites -gt 0 -and $script:WriteCount -eq $FaultInjectionAfterWrites) { throw "Injected runtime update failure after write $script:WriteCount." }
  if ((Get-Sha256 $Target) -ne ([string]$Item.sha256).ToLowerInvariant()) { throw "Deployed hash mismatch: $($Item.target)" }
  [void]$CreatedOrReplaced.Add([string]$Item.target)
}

try {
  try { $LockStream = [IO.File]::Open($LockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
  catch { throw "Another runtime transaction is active for this project: $LockPath" }
  New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
  foreach ($Relative in @($Map.target) + $ConditionalState | Sort-Object -Unique) { Backup-Path $Relative }
  Write-JsonAtomic -Path (Join-Path $BackupRoot 'journal.json') -Value ([ordered]@{ schema_version = '1.0.0'; transaction_id = $TransactionId; phase = 'backed_up'; source_commit = $SourceCommit; project_root = $Project; product_baseline_sha256 = $ProductBeforeIdentity; paths = $BackupIndex.ToArray() }) -Depth 30

  foreach ($Item in @($Map | Where-Object { $_.mode -ne 'activate_last' })) { Copy-MapItem $Item }

  if (-not $SkipActiveWorkItemMigration) {
    $Agy = Join-Path $Project '.agy'
    $WorkItemPath = Join-Path $Agy 'WORK_ITEM.json'
    if (Test-Path -LiteralPath $WorkItemPath -PathType Leaf) {
      $MutationStarted = $true
      $WorkItem = Get-Content -LiteralPath $WorkItemPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ((Get-OptionalProperty $WorkItem 'owner_approved' $false) -ne $true) { throw 'Active work item is not owner-approved; authority adoption refused.' }
      $WorkItemId = [string](Get-OptionalProperty $WorkItem 'work_item_id' '')
      $GoalEpoch = [int](Get-OptionalProperty $WorkItem 'goal_epoch' -1)
      if ([string]::IsNullOrWhiteSpace($WorkItemId) -or $GoalEpoch -lt 0) { throw 'Active work-item identity is incomplete.' }
      foreach ($Name in @('convergence_policy', 'repair_budget', 'repair_batches_used', 'repair_batch_limit')) { Remove-JsonProperty $WorkItem $Name }
      Set-JsonProperty $WorkItem 'progress_policy' ([ordered]@{ auto_continue_while_progress = $true; consecutive_no_progress_limit = 2; same_failure_limit = 2 })
      Write-JsonAtomic $WorkItemPath $WorkItem

      $NextPath = Join-Path $Agy 'NEXT_ACTION.json'
      $NextExisting = if (Test-Path -LiteralPath $NextPath -PathType Leaf) { Get-Content -LiteralPath $NextPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
      $Route = [string](Get-OptionalProperty $NextExisting 'route' (Get-OptionalProperty $WorkItem 'preferred_command' '/nextphase'))
      if ($Route -notin @('/nextphase', '/fixcritical', '/auditphase', '/fastpatch', '/shipcheck')) { $Route = '/nextphase' }
      $MigrationTime = (Get-Date).ToUniversalTime().ToString('o')
      $ProgressPath = Join-Path $Agy 'PROGRESS_STATE.json'
      $Progress = if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) { Get-Content -LiteralPath $ProgressPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
      Set-JsonProperty $Progress 'schema_version' '1.1.0'; Set-JsonProperty $Progress 'work_item_id' $WorkItemId; Set-JsonProperty $Progress 'status' 'progressing'
      Set-JsonProperty $Progress 'consecutive_no_progress' ([int](Get-OptionalProperty $Progress 'consecutive_no_progress' 0)); Set-JsonProperty $Progress 'same_failure_count' ([int](Get-OptionalProperty $Progress 'same_failure_count' 0))
      Set-JsonProperty $Progress 'owner_decision_required' $false; Set-JsonProperty $Progress 'owner_decision_reason' $null
      if ($null -eq $Progress.PSObject.Properties['history']) { Set-JsonProperty $Progress 'history' @([ordered]@{ at_utc = $MigrationTime; event = 'runtime_1.2.9_authority_adoption'; route = $Route }) }
      Set-JsonProperty $Progress 'updated_at_utc' $MigrationTime
      Write-JsonAtomic $ProgressPath $Progress
      $Next = [ordered]@{ schema_version = '1.1.0'; work_item_id = $WorkItemId; route = $Route; auto_continue = $true; owner_decision_required = $false; owner_decision_reason = $null; technical_task_path = if (Test-Path -LiteralPath (Join-Path $Agy 'inbox\ACTIVE_ACTION_PACKET\AGENT_TASK.md')) { '.agy/inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md' } else { $null }; updated_at_utc = $MigrationTime }
      Write-JsonAtomic $NextPath $Next

      $ScopePath = Join-Path $Agy 'EXECUTION_SCOPE.json'; $LeasePath = Join-Path $Agy 'EXECUTION_LEASE.json'; $FirewallPath = Join-Path $Agy 'STAGE_FIREWALL.json'
      foreach ($Required in @($ScopePath, $LeasePath, $FirewallPath)) { if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Active authority file missing: $Required" } }
      $Scope = Get-Content -LiteralPath $ScopePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $Lease = Get-Content -LiteralPath $LeasePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $Firewall = Get-Content -LiteralPath $FirewallPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ([string](Get-OptionalProperty $Scope 'work_item_id' '') -ne $WorkItemId -or [string](Get-OptionalProperty $Lease 'work_item_id' '') -ne $WorkItemId -or [string](Get-OptionalProperty $Firewall 'work_item_id' '') -ne $WorkItemId) { throw 'Legacy authority does not match the active work item.' }
      if ([int](Get-OptionalProperty $Lease 'goal_epoch' -1) -ne $GoalEpoch) { throw 'Legacy lease goal epoch does not match the active work item.' }
      $AllowedPaths = @((Get-OptionalProperty $Scope 'allowed_paths' @()))
      if ($AllowedPaths.Count -eq 0) { throw 'Legacy execution scope has no allowed paths.' }
      Set-JsonProperty $Scope 'status' 'exact'; Set-JsonProperty $Scope 'project_root' $Project; Set-JsonProperty $Scope 'route' $Route
      Write-JsonAtomic $ScopePath $Scope
      $ScopeHash = Get-Sha256 $ScopePath

      $Branch = (Invoke-Git @('branch', '--show-current')).StdOut.Trim(); $Head = (Invoke-Git @('rev-parse', 'HEAD')).StdOut.Trim(); $GitRoot = (Invoke-Git @('rev-parse', '--show-toplevel')).StdOut.Trim()
      if ([IO.Path]::GetFullPath($GitRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath($Project).TrimEnd('\')) { throw 'Target project root is not the exact Git worktree root.' }
      Set-JsonProperty $Lease 'status' 'active'; Set-JsonProperty $Lease 'project_root' $Project; Set-JsonProperty $Lease 'worktree_root' $Project; Set-JsonProperty $Lease 'branch' $Branch
      Set-JsonProperty $Lease 'owner_goal_sha256' (Get-TextSha256 ([string]$WorkItem.goal)); Set-JsonProperty $Lease 'execution_scope_sha256' $ScopeHash; Set-JsonProperty $Lease 'allowed_paths' $AllowedPaths; Set-JsonProperty $Lease 'route' $Route
      Write-JsonAtomic $LeasePath $Lease

      Set-JsonProperty $Firewall 'status' 'active'; Set-JsonProperty $Firewall 'work_item_id' $WorkItemId
      if ($null -eq $Firewall.PSObject.Properties['protected_path_patterns']) { Set-JsonProperty $Firewall 'protected_path_patterns' $AllowedPaths }
      $AlgorithmAuthorized = [string](Get-OptionalProperty $Firewall 'active_sub_scope' '') -eq 'algorithm_repair'
      Set-JsonProperty $Firewall 'algorithm_repair_authorized' $AlgorithmAuthorized
      Write-JsonAtomic $FirewallPath $Firewall

      $WorkTransactionPath = Join-Path $Agy 'WORK_ITEM_TRANSACTION.json'
      $WorkTransaction = if (Test-Path -LiteralPath $WorkTransactionPath -PathType Leaf) { Get-Content -LiteralPath $WorkTransactionPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
      Set-JsonProperty $WorkTransaction 'schema_version' '1.1.0'; Set-JsonProperty $WorkTransaction 'status' 'committed'; Set-JsonProperty $WorkTransaction 'transaction_id' ('adopted-work-item-' + (Get-TextSha256 $WorkItemId).Substring(0, 20)); Set-JsonProperty $WorkTransaction 'work_item_id' $WorkItemId; Set-JsonProperty $WorkTransaction 'goal_epoch' $GoalEpoch; Set-JsonProperty $WorkTransaction 'committed_at_utc' (Get-OptionalProperty $WorkTransaction 'committed_at_utc' $MigrationTime)
      Write-JsonAtomic $WorkTransactionPath $WorkTransaction

      $LeaseId = [string](Get-OptionalProperty $Lease 'lease_id' '')
      if ([string]::IsNullOrWhiteSpace($LeaseId)) { throw 'Legacy active lease has no lease_id.' }
      $AuthorityTransaction = [ordered]@{ schema_version = '1.1.0'; status = 'committed'; transaction_id = 'adopted-authority-' + (Get-TextSha256 $LeaseId).Substring(0, 20); work_item_id = $WorkItemId; goal_epoch = $GoalEpoch; lease_id = $LeaseId; branch = $Branch; baseline_head = [string](Get-OptionalProperty $Lease 'baseline_head' $Head); route = $Route; files = [ordered]@{ 'EXECUTION_SCOPE.json' = [ordered]@{ sha256 = Get-Sha256 $ScopePath }; 'STAGE_FIREWALL.json' = [ordered]@{ sha256 = Get-Sha256 $FirewallPath } }; committed_at_utc = $MigrationTime }
      Write-JsonAtomic (Join-Path $Agy 'EXECUTION_AUTHORITY_TRANSACTION.json') $AuthorityTransaction

      $InventoryHash = Get-Sha256 (Join-Path $Project '.agents\COMMAND_INVENTORY.json')
      $Handshake = [ordered]@{ schema_version = '1.2.0'; ecosystem_version = $EcosystemVersion; generated_at_utc = $MigrationTime; project_root = $Project; source_commit = $SourceCommit; release_asset_sha256 = if ($AssetSha256) { $AssetSha256.ToLowerInvariant() } else { $null }; command_inventory_sha256 = $InventoryHash; git = [ordered]@{ branch = $Branch; head_commit = $Head; git_state = if ($StatusResult.StdOut.Length -gt 0) { 'dirty' } else { 'clean' } }; installed = [ordered]@{ package_version = $EcosystemVersion; runtime_version = $EcosystemVersion; companion_version = $EcosystemVersion }; work_item = [ordered]@{ work_item_id = $WorkItemId; goal_epoch = $GoalEpoch; status = [string]$WorkItem.status }; routing = [ordered]@{ routing_valid = $true; resolved_commands_allowed_now = @($Route); next_required_command = $Route; product_execution_allowed = ($Route -in @('/nextphase', '/fixcritical', '/fastpatch')); release_execution_allowed = ($Route -eq '/shipcheck') }; execution_lease_id = $LeaseId; progress_guard = [ordered]@{ numeric_repair_budget = $false; auto_continue_while_progress = $true; consecutive_no_progress_limit = 2; same_failure_limit = 2 } }
      Write-JsonAtomic (Join-Path $Agy 'RUNTIME_HANDSHAKE.json') $Handshake

      foreach ($LegacyName in @('CONVERGENCE_BUDGET.json', 'REPAIR_BUDGET.json', 'repair-ledger.ndjson')) {
        $LegacyPath = Join-Path $Agy $LegacyName
        if (Test-Path -LiteralPath $LegacyPath -PathType Leaf) {
          $ArchivePath = Join-Path $Agy ('history\legacy-repair-budget\runtime-1.2.9\' + $LegacyName)
          Write-BytesAtomic $ArchivePath ([IO.File]::ReadAllBytes($LegacyPath))
          Remove-Item -LiteralPath $LegacyPath -Force
        }
      }
      $MigrationReceipt = [ordered]@{ schema_version = '1.2.9'; ecosystem_version = $EcosystemVersion; status = 'PASS'; work_item_id = $WorkItemId; goal_epoch = $GoalEpoch; lease_id = $LeaseId; source_commit = $SourceCommit; numeric_repair_budget_enabled = $false; authority_adopted = $true; generated_at_utc = $MigrationTime }
      Write-JsonAtomic $MigrationResultPath $MigrationReceipt
    }
    else {
      Write-JsonAtomic $MigrationResultPath ([ordered]@{ schema_version = '1.2.9'; ecosystem_version = $EcosystemVersion; status = 'PASS'; work_item_id = $null; numeric_repair_budget_enabled = $false; authority_adopted = $false; generated_at_utc = (Get-Date).ToUniversalTime().ToString('o') })
    }
  }

  $HookScript = Join-Path $Project '.agents\hooks\agentic_runtime_hook.cjs'
  $ForbiddenCanary = Join-Path $Project '.agentic-runtime-forbidden-canary.tmp'
  $CanaryPayload = @{ workspacePaths = @($Project); toolCall = @{ args = @{ TargetFile = $ForbiddenCanary } } } | ConvertTo-Json -Depth 10 -Compress
  $CanaryResult = $CanaryPayload | & node $HookScript prewrite | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw 'Deployed pre-write hook canary process failed.' }
  if ([string]$CanaryResult.decision -ne 'deny' -or (Test-Path -LiteralPath $ForbiddenCanary)) { throw 'Deployed pre-write hook did not deny an out-of-lease target before mutation.' }

  foreach ($Item in @($Map | Where-Object { $_.mode -eq 'activate_last' })) { Copy-MapItem $Item }
  Invoke-DeployedValidation

  $ProductAfter = @(Get-ProductSnapshot)
  $ProductAfterIdentity = Get-SnapshotIdentity $ProductAfter
  if ($ProductAfterIdentity -ne $ProductBeforeIdentity) { throw 'Product source baseline changed during runtime deployment.' }

  $InstallTime = (Get-Date).ToUniversalTime().ToString('o')
  $Installed = [ordered]@{ schema_version = '1.2.9'; ecosystem_version = $EcosystemVersion; installed_at_utc = $InstallTime; package_version = $EcosystemVersion; runtime_version = $EcosystemVersion; playbook_version = $EcosystemVersion; companion_version = $EcosystemVersion; mode = 'runtime-update'; state_profile = 'preserved'; source_repo = 'agentic-pipeline'; source_commit = $SourceCommit; release_asset_sha256 = if ($AssetSha256) { $AssetSha256.ToLowerInvariant() } else { $null }; conflict_policy = 'manifest-owned-transaction'; copied = $CreatedOrReplaced.ToArray(); skipped = $Skipped.ToArray(); backed_up = @($BackupIndex | Where-Object { $_.existed } | ForEach-Object { $_.relative }); backup_root = $BackupRoot; product_baseline_before_sha256 = $ProductBeforeIdentity; product_baseline_after_sha256 = $ProductAfterIdentity; next_command = $null }
  Write-JsonAtomic $InstallationPath $Installed
  $Result = [ordered]@{ schema_version = '1.2.9'; ecosystem_version = $EcosystemVersion; status = 'PASS'; project_root = $Project; package_version = $EcosystemVersion; runtime_version = $EcosystemVersion; companion_version = $EcosystemVersion; source_commit = $SourceCommit; release_asset_sha256 = if ($AssetSha256) { $AssetSha256.ToLowerInvariant() } else { $null }; copied = $CreatedOrReplaced.ToArray(); skipped = $Skipped.ToArray(); backup_root = $BackupRoot; product_source_modified = ($ProductAfterIdentity -ne $ProductBeforeIdentity); product_baseline_sha256 = $ProductAfterIdentity; active_work_item_migrated = (-not $SkipActiveWorkItemMigration); prewrite_guard_canary = 'PASS'; generated_at_utc = $InstallTime }
  Write-JsonAtomic $RuntimeResultPath $Result
  Write-JsonAtomic -Path (Join-Path $BackupRoot 'journal.json') -Value ([ordered]@{ schema_version = '1.0.0'; transaction_id = $TransactionId; phase = 'committed'; source_commit = $SourceCommit; project_root = $Project; product_baseline_before_sha256 = $ProductBeforeIdentity; product_baseline_after_sha256 = $ProductAfterIdentity; paths = $BackupIndex.ToArray() }) -Depth 30
  Write-Host 'PROJECT RUNTIME 1.2.9 UPDATE COMPLETED.' -ForegroundColor Green
}
catch {
  if ($MutationStarted) {
    Write-Warning 'Runtime update failed. Restoring every journaled framework-owned path.'
    Restore-Transaction
    Write-Warning "Rollback completed from: $BackupRoot"
  }
  throw
}
finally {
  if ($null -ne $LockStream) { $LockStream.Dispose() }
  Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
}
