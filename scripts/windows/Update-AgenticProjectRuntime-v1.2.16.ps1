[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ProjectRoot,
  [string]$RuntimeRoot = '',
  [string]$RepoRoot = '',
  [string]$RuntimeArchivePath = '',
  [string]$AssetSha256 = '',
  [string]$ExpectedSourceCommit = '',
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
$EcosystemVersion = '1.2.16'
$PathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$PathSeparators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
  $RuntimeRoot = if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot } else { (Join-Path $PSScriptRoot '../..') }
}
$SourceRoot = (Resolve-Path -LiteralPath $RuntimeRoot).Path
$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
. (Join-Path $SourceRoot 'scripts/windows/common/NativeProcess.ps1')

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

function Get-BytesSha256([byte[]]$Bytes) {
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try { return ([Convert]::ToHexString($Hasher.ComputeHash($Bytes))).ToLowerInvariant() }
  finally { $Hasher.Dispose() }
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
  $RootFull = [IO.Path]::GetFullPath($Root).TrimEnd($PathSeparators)
  $PlatformRelative = $Normalized.Replace([char]'/', [IO.Path]::DirectorySeparatorChar)
  $Resolved = [IO.Path]::GetFullPath((Join-Path $RootFull $PlatformRelative))
  if (-not $Resolved.StartsWith($RootFull + [IO.Path]::DirectorySeparatorChar, $PathComparison)) { throw "Path escapes root: $Relative" }
  if ($RejectReparseParents) {
    $Cursor = Split-Path -Parent $Resolved
    while ($Cursor.Length -ge $RootFull.Length -and $Cursor.StartsWith($RootFull, $PathComparison)) {
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
if ($SourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
  $SourceIdentityPath = Join-Path $SourceRoot 'SOURCE_IDENTITY.json'
  if (Test-Path -LiteralPath $SourceIdentityPath -PathType Leaf) {
    $SourceIdentity = Get-Content -LiteralPath $SourceIdentityPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ArchivedCommit = [string](Get-OptionalProperty $SourceIdentity 'source_commit' '')
    if ($ArchivedCommit -match '^[0-9a-fA-F]{40}$') { $SourceCommit = $ArchivedCommit }
  }
}
if ($SourceCommit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Runtime source commit is missing or invalid.' }
if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit)) {
  if ($ExpectedSourceCommit -notmatch '^[0-9a-fA-F]{40}$' -or $SourceCommit.ToLowerInvariant() -cne $ExpectedSourceCommit.ToLowerInvariant()) {
    throw 'Runtime source commit does not match ExpectedSourceCommit.'
  }
}

if ($null -ne $OverlayManifest) {
  if ([string]::IsNullOrWhiteSpace($ExpectedSourceCommit)) { throw 'ExpectedSourceCommit is required when installing an extracted release asset.' }
  if ([string]::IsNullOrWhiteSpace($RuntimeArchivePath) -or -not (Test-Path -LiteralPath $RuntimeArchivePath -PathType Leaf)) { throw 'RuntimeArchivePath is required when installing an extracted release asset.' }
  if ($AssetSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'A verified 64-hex AssetSha256 is required for an extracted release asset.' }
  $ArchiveFull = (Resolve-Path -LiteralPath $RuntimeArchivePath).Path
  $ActualAssetSha = (Get-FileHash -LiteralPath $ArchiveFull -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($AssetSha256.ToLowerInvariant() -ne $ActualAssetSha) { throw 'Runtime archive SHA-256 does not match AssetSha256.' }
  $AssetSha256 = $ActualAssetSha
  $Archive = [IO.Compression.ZipFile]::OpenRead($ArchiveFull)
  try {
    $ManifestEntries = @($Archive.Entries | Where-Object { $_.FullName.Replace('\','/') -match '(^|/)RUNTIME_OVERLAY_MANIFEST\.json$' })
    if ($ManifestEntries.Count -ne 1) { throw "Runtime archive must contain exactly one overlay manifest; found $($ManifestEntries.Count)." }
    $ManifestStream = $ManifestEntries[0].Open()
    try {
      $ManifestBytes = [IO.MemoryStream]::new()
      try { $ManifestStream.CopyTo($ManifestBytes); $ArchiveManifestSha = Get-BytesSha256 $ManifestBytes.ToArray() }
      finally { $ManifestBytes.Dispose() }
    }
    finally { $ManifestStream.Dispose() }
  }
  finally { $Archive.Dispose() }
  if ((Get-Sha256 $ManifestPath) -ne $ArchiveManifestSha) { throw 'Extracted runtime manifest does not match the exact verified archive.' }
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
if ($AllowedDeploymentTargets.Count -ne 80) { throw "Internal runtime allowlist is incomplete: $($AllowedDeploymentTargets.Count) targets." }
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

$FindingsRelative = '.agy/FINDINGS.json'
$LegacyFindingsArchiveRelative = ".agy/history/legacy-findings/runtime-$EcosystemVersion/FINDINGS.json"
$ConditionalState = @(
  '.agy/WORK_ITEM.json', '.agy/WORK_ITEM_TRANSACTION.json', '.agy/EXECUTION_SCOPE.json', '.agy/EXECUTION_LEASE.json',
  '.agy/EXECUTION_AUTHORITY_TRANSACTION.json', '.agy/STAGE_FIREWALL.json', '.agy/RUNTIME_HANDSHAKE.json',
  '.agy/PROGRESS_STATE.json', '.agy/NEXT_ACTION.json', '.agy/OWNER_AUTONOMY_MIGRATION_RESULT.json',
  '.agy/CONVERGENCE_BUDGET.json', '.agy/REPAIR_BUDGET.json', '.agy/repair-ledger.ndjson',
  '.agy/history/legacy-repair-budget/runtime-1.2.9/CONVERGENCE_BUDGET.json',
  '.agy/history/legacy-repair-budget/runtime-1.2.9/REPAIR_BUDGET.json',
  '.agy/history/legacy-repair-budget/runtime-1.2.9/repair-ledger.ndjson',
  $FindingsRelative, $LegacyFindingsArchiveRelative,
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

function Test-SamePath([string]$Left, [string]$Right) {
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
  return [IO.Path]::GetFullPath($Left).TrimEnd($PathSeparators).Equals([IO.Path]::GetFullPath($Right).TrimEnd($PathSeparators), $PathComparison)
}

function Test-ExactPropertySet([object]$Object, [string[]]$Expected) {
  if ($null -eq $Object -or $Object -is [System.Array] -or $Object -is [string]) { return $false }
  $Actual = @($Object.PSObject.Properties.Name)
  if ($Actual.Count -ne $Expected.Count) { return $false }
  foreach ($Name in $Actual) { if ($Expected -cnotcontains $Name) { return $false } }
  return $true
}

function Test-CanonicalFindingSetDocument([object]$Document) {
  $TopProperties = @('schema_version','work_item_id','target_head','findings','updated_at_utc')
  if (-not (Test-ExactPropertySet $Document $TopProperties)) { return $false }
  if ([string](Get-OptionalProperty $Document 'schema_version' '') -cne '1.0.0') { return $false }
  foreach ($Name in @('work_item_id','target_head','updated_at_utc')) { if ((Get-OptionalProperty $Document $Name) -isnot [string]) { return $false } }
  $Findings = $Document.PSObject.Properties['findings'].Value
  if ($Findings -isnot [System.Array]) { return $false }

  $AllowedProperties = @('finding_id','title','category','severity','lifecycle_status','phase_classification','evidence','implementation_alignment_status','empirical_validation_status','production_use_status','notes','materiality','auto_repairable','owner_decision_required','owner_decision_type','origin','coverage_id','audit_cycle','repair_batch_id')
  $Categories = @('safety','security_privacy','data_integrity','research_validity','reproducibility','delivery','observability','cosmetic')
  $Severities = @('blocker','high','medium','low','info')
  $Lifecycles = @('open_confirmed','fixed_unverified','verified_resolved','deferred','accepted_risk','false_positive','superseded')
  $Phases = @('current_phase_blocker','next_phase_requirement','deferred_debt','accepted_risk','false_positive','superseded')
  $Materialities = @('product_blocker','verification_blocker','release_blocker','service_warning','cosmetic')
  $OwnerDecisionTypes = @('scope_or_requirement_change','destructive_or_irreversible_action','release_or_publication','credentials_private_data_or_paid_access','material_risk_acceptance','normative_protocol_change','required_capability_unavailable')
  $Ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($Finding in @($Findings)) {
    if ($null -eq $Finding -or $Finding -is [System.Array] -or $Finding -is [string]) { return $false }
    foreach ($Name in @($Finding.PSObject.Properties.Name)) { if ($AllowedProperties -cnotcontains $Name) { return $false } }
    foreach ($Name in @('finding_id','title','category','severity','lifecycle_status','phase_classification','materiality','auto_repairable','owner_decision_required')) {
      if ($null -eq $Finding.PSObject.Properties[$Name]) { return $false }
    }
    $FindingId = Get-OptionalProperty $Finding 'finding_id'
    $Title = Get-OptionalProperty $Finding 'title'
    if ($FindingId -isnot [string] -or [string]::IsNullOrWhiteSpace($FindingId) -or $Title -isnot [string] -or [string]::IsNullOrWhiteSpace($Title)) { return $false }
    if (-not $Ids.Add([string]$FindingId)) { return $false }
    if ($Categories -cnotcontains [string]$Finding.category -or $Severities -cnotcontains [string]$Finding.severity -or $Lifecycles -cnotcontains [string]$Finding.lifecycle_status -or $Phases -cnotcontains [string]$Finding.phase_classification -or $Materialities -cnotcontains [string]$Finding.materiality) { return $false }
    if ($Finding.auto_repairable -isnot [bool] -or $Finding.owner_decision_required -isnot [bool]) { return $false }
    $OwnerDecisionType = Get-OptionalProperty $Finding 'owner_decision_type'
    if ($Finding.owner_decision_required -eq $true) {
      if ($Finding.auto_repairable -eq $true -or $OwnerDecisionTypes -cnotcontains [string]$OwnerDecisionType) { return $false }
    }
    elseif ($null -ne $OwnerDecisionType) { return $false }
    if ($null -ne $Finding.PSObject.Properties['evidence']) {
      $Evidence = $Finding.PSObject.Properties['evidence'].Value
      if ($Evidence -isnot [System.Array] -or @($Evidence | Where-Object { $_ -isnot [string] }).Count -gt 0) { return $false }
    }
    if ($null -ne $Finding.PSObject.Properties['implementation_alignment_status'] -and @('unknown','misaligned','aligned','resolved') -cnotcontains [string]$Finding.implementation_alignment_status) { return $false }
    if ($null -ne $Finding.PSObject.Properties['empirical_validation_status'] -and @('not_applicable','unknown','unvalidated','partially_validated','validated') -cnotcontains [string]$Finding.empirical_validation_status) { return $false }
    if ($null -ne $Finding.PSObject.Properties['production_use_status'] -and @('unknown','blocked','conditional','allowed') -cnotcontains [string]$Finding.production_use_status) { return $false }
    if ($null -ne $Finding.PSObject.Properties['origin'] -and @('initial_audit','audit_coverage_miss','verification','owner_change','runtime') -cnotcontains [string]$Finding.origin) { return $false }
    if ($null -ne $Finding.PSObject.Properties['notes'] -and $Finding.notes -isnot [string]) { return $false }
    foreach ($Name in @('coverage_id','audit_cycle','repair_batch_id')) {
      if ($null -ne $Finding.PSObject.Properties[$Name]) {
        $Value = $Finding.PSObject.Properties[$Name].Value
        if ($null -ne $Value -and $Value -isnot [string]) { return $false }
      }
    }
  }
  return $true
}

function Convert-LegacyFindingCategory([string]$Value) {
  switch -CaseSensitive ($Value) {
    'adapter_placeholder' { return 'delivery' }
    'algorithm_defect' { return 'research_validity' }
    'audit_candidate_unbound' { return 'reproducibility' }
    'coverage_matrix_incomplete' { return 'reproducibility' }
    'evidence_gap' { return 'reproducibility' }
    'external_dependency' { return 'delivery' }
    'findings_schema_invalid' { return 'data_integrity' }
    'governance_gap' { return 'safety' }
    'lease_authority_defective' { return 'safety' }
    'oracle_circularity' { return 'research_validity' }
    'repair_delta_missing' { return 'observability' }
    'report_mismatch' { return 'data_integrity' }
    'runtime_routing_stale' { return 'safety' }
    'stage_firewall_absent' { return 'safety' }
    'test_evidence_gap' { return 'reproducibility' }
    'timestamp_not_utc' { return 'data_integrity' }
    'work_item_corruption' { return 'data_integrity' }
  }
  throw "Unsupported legacy finding category: $Value"
}

function Convert-LegacyFindingOrigin([string]$Value) {
  switch -CaseSensitive ($Value) {
    'initial_audit' { return 'initial_audit' }
    'audit_coverage_miss' { return 'audit_coverage_miss' }
    'authority_audit' { return 'verification' }
  }
  throw "Unsupported legacy finding origin: $Value"
}

function Convert-LegacyFindingSeverity([string]$Materiality) {
  switch -CaseSensitive ($Materiality) {
    'product_blocker' { return 'blocker' }
    'verification_blocker' { return 'high' }
  }
  throw "Unsupported legacy finding materiality: $Materiality"
}

function Convert-LegacyFindingPhase([string]$Lifecycle) {
  switch -CaseSensitive ($Lifecycle) {
    'open_confirmed' { return 'current_phase_blocker' }
    'fixed_unverified' { return 'current_phase_blocker' }
    'verified_resolved' { return 'current_phase_blocker' }
    'deferred' { return 'deferred_debt' }
  }
  throw "Unsupported legacy finding lifecycle: $Lifecycle"
}

function Test-LegacyFindingsPreconditions {
  $FindingsPath = Resolve-ConfinedPath -Root $Project -Relative $FindingsRelative
  if (-not (Test-Path -LiteralPath $FindingsPath -PathType Leaf)) {
    return [pscustomobject]@{ state='absent'; requires_migration=$false; source_sha256=$null; source_bytes=$null; migrated_document=$null; archive_relative=$LegacyFindingsArchiveRelative }
  }

  [byte[]]$SourceBytes = [IO.File]::ReadAllBytes($FindingsPath)
  $SourceSha = Get-BytesSha256 $SourceBytes
  try {
    $JsonText = [Text.UTF8Encoding]::new($false, $true).GetString($SourceBytes)
    $Document = $JsonText | ConvertFrom-Json -Depth 100 -DateKind String
  }
  catch { throw "FINDINGS.json is not strict UTF-8 JSON; migration refused: $($_.Exception.Message)" }

  if (Test-CanonicalFindingSetDocument $Document) {
    return [pscustomobject]@{ state='canonical'; requires_migration=$false; source_sha256=$SourceSha; source_bytes=$null; migrated_document=$null; archive_relative=$LegacyFindingsArchiveRelative }
  }

  $LegacyTopProperties = @('schema_version','work_item_id','target_head','candidate_manifest_id','findings','updated_at_utc')
  $LegacyFindingProperties = @('finding_id','title','category','description','affected_paths','lifecycle_status','materiality','origin','coverage_id')
  if (-not (Test-ExactPropertySet $Document $LegacyTopProperties)) { throw 'FINDINGS.json is neither canonical nor the exact recognized legacy finding-set shape.' }
  if ([string](Get-OptionalProperty $Document 'schema_version' '') -cne '1.0.0') { throw 'Legacy FINDINGS.json schema_version is unsupported.' }
  foreach ($Name in @('work_item_id','candidate_manifest_id')) {
    $Value = Get-OptionalProperty $Document $Name
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw "Legacy FINDINGS.json $Name is missing or invalid." }
  }
  if ((Get-OptionalProperty $Document 'target_head') -isnot [string] -or [string]$Document.target_head -notmatch '^[0-9a-f]{40}$') { throw 'Legacy FINDINGS.json target_head is invalid.' }
  if ((Get-OptionalProperty $Document 'updated_at_utc') -isnot [string] -or [string]$Document.updated_at_utc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$') { throw 'Legacy FINDINGS.json updated_at_utc is not canonical UTC.' }
  $LegacyFindings = $Document.PSObject.Properties['findings'].Value
  if ($LegacyFindings -isnot [System.Array] -or @($LegacyFindings).Count -eq 0) { throw 'Legacy FINDINGS.json findings must be a non-empty array.' }

  $MigratedFindings = New-Object System.Collections.Generic.List[object]
  $Ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($Legacy in @($LegacyFindings)) {
    if (-not (Test-ExactPropertySet $Legacy $LegacyFindingProperties)) { throw 'Legacy FINDINGS.json contains an unknown finding shape.' }
    foreach ($Name in @('finding_id','title','category','description','lifecycle_status','materiality','origin','coverage_id')) {
      $Value = Get-OptionalProperty $Legacy $Name
      if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw "Legacy finding $Name is missing or invalid." }
    }
    if (-not $Ids.Add([string]$Legacy.finding_id)) { throw "Legacy FINDINGS.json contains duplicate finding_id: $($Legacy.finding_id)" }
    $AffectedValue = $Legacy.PSObject.Properties['affected_paths'].Value
    if ($AffectedValue -isnot [System.Array] -or @($AffectedValue).Count -eq 0 -or @($AffectedValue | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) { throw "Legacy finding affected_paths is invalid: $($Legacy.finding_id)" }
    $MappedCategory = Convert-LegacyFindingCategory ([string]$Legacy.category)
    $MappedOrigin = Convert-LegacyFindingOrigin ([string]$Legacy.origin)
    $MappedSeverity = Convert-LegacyFindingSeverity ([string]$Legacy.materiality)
    $MappedPhase = Convert-LegacyFindingPhase ([string]$Legacy.lifecycle_status)
    $Notes = "{0}`n`nLegacy category: {1}; legacy origin: {2}; exact source: {3}" -f [string]$Legacy.description, [string]$Legacy.category, [string]$Legacy.origin, $LegacyFindingsArchiveRelative
    [void]$MigratedFindings.Add([ordered]@{
      finding_id = [string]$Legacy.finding_id
      title = [string]$Legacy.title
      category = $MappedCategory
      severity = $MappedSeverity
      lifecycle_status = [string]$Legacy.lifecycle_status
      phase_classification = $MappedPhase
      evidence = [object[]]@($AffectedValue)
      notes = $Notes
      materiality = [string]$Legacy.materiality
      auto_repairable = $false
      owner_decision_required = $false
      origin = $MappedOrigin
      coverage_id = [string]$Legacy.coverage_id
    })
  }
  $MigratedDocument = [ordered]@{
    schema_version = '1.0.0'
    work_item_id = [string]$Document.work_item_id
    target_head = [string]$Document.target_head
    findings = [object[]]$MigratedFindings.ToArray()
    updated_at_utc = [string]$Document.updated_at_utc
  }
  $MigratedRoundTrip = ($MigratedDocument | ConvertTo-Json -Depth 40) | ConvertFrom-Json -Depth 100 -DateKind String
  if (-not (Test-CanonicalFindingSetDocument $MigratedRoundTrip)) { throw 'Internal legacy FINDINGS.json mapping did not produce a canonical finding set.' }

  $ArchivePath = Resolve-ConfinedPath -Root $Project -Relative $LegacyFindingsArchiveRelative
  if ((Test-Path -LiteralPath $ArchivePath -PathType Leaf) -and (Get-Sha256 $ArchivePath) -cne $SourceSha) { throw 'Existing legacy FINDINGS.json history archive does not match the exact source bytes.' }
  return [pscustomobject]@{ state='legacy'; requires_migration=$true; source_sha256=$SourceSha; source_bytes=$SourceBytes; migrated_document=$MigratedDocument; archive_relative=$LegacyFindingsArchiveRelative }
}

function Test-LegacyAuthorityPreconditions {
  if ($SkipActiveWorkItemMigration) { return $null }
  $Agy = Join-Path $Project '.agy'
  $WorkItemPath = Join-Path $Agy 'WORK_ITEM.json'
  if (-not (Test-Path -LiteralPath $WorkItemPath -PathType Leaf)) { return $null }

  $ScopePath = Join-Path $Agy 'EXECUTION_SCOPE.json'
  $LeasePath = Join-Path $Agy 'EXECUTION_LEASE.json'
  $FirewallPath = Join-Path $Agy 'STAGE_FIREWALL.json'
  foreach ($Required in @($ScopePath, $LeasePath, $FirewallPath)) {
    if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Active authority file missing: $Required" }
  }

  $WorkItem = Get-Content -LiteralPath $WorkItemPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $Scope = Get-Content -LiteralPath $ScopePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $Lease = Get-Content -LiteralPath $LeasePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $Firewall = Get-Content -LiteralPath $FirewallPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ((Get-OptionalProperty $WorkItem 'owner_approved' $false) -ne $true) { throw 'Active work item is not owner-approved; authority adoption refused.' }
  $WorkItemId = [string](Get-OptionalProperty $WorkItem 'work_item_id' '')
  $GoalEpoch = [int](Get-OptionalProperty $WorkItem 'goal_epoch' -1)
  $Goal = [string](Get-OptionalProperty $WorkItem 'goal' '')
  if ([string]::IsNullOrWhiteSpace($WorkItemId) -or $GoalEpoch -lt 0 -or [string]::IsNullOrWhiteSpace($Goal)) { throw 'Active work-item identity is incomplete.' }
  if ([string](Get-OptionalProperty $Scope 'work_item_id' '') -ne $WorkItemId -or [string](Get-OptionalProperty $Lease 'work_item_id' '') -ne $WorkItemId -or [string](Get-OptionalProperty $Firewall 'work_item_id' '') -ne $WorkItemId) { throw 'Legacy authority does not match the active work item.' }
  if ([int](Get-OptionalProperty $Lease 'goal_epoch' -1) -ne $GoalEpoch) { throw 'Legacy lease goal epoch does not match the active work item.' }
  if ([string](Get-OptionalProperty $Lease 'status' '') -ne 'active') { throw 'Legacy execution lease is not active.' }

  $GitRoot = (Invoke-Git @('rev-parse', '--show-toplevel')).StdOut.Trim()
  $Branch = (Invoke-Git @('branch', '--show-current')).StdOut.Trim()
  $Head = (Invoke-Git @('rev-parse', 'HEAD')).StdOut.Trim()
  if (-not (Test-SamePath $GitRoot $Project)) { throw 'Target project root is not the exact Git worktree root.' }
  if (-not (Test-SamePath ([string](Get-OptionalProperty $Lease 'project_root' '')) $Project) -or -not (Test-SamePath ([string](Get-OptionalProperty $Lease 'worktree_root' '')) $Project)) { throw 'Legacy lease is bound to a different project/worktree root.' }
  $ScopeProjectRoot = [string](Get-OptionalProperty $Scope 'project_root' '')
  if (-not [string]::IsNullOrWhiteSpace($ScopeProjectRoot) -and -not (Test-SamePath $ScopeProjectRoot $Project)) { throw 'Legacy execution scope is bound to a different project root.' }
  if ([string](Get-OptionalProperty $Lease 'branch' '') -cne $Branch) { throw 'Legacy execution lease is bound to a different branch.' }

  $ScopeStatus = [string](Get-OptionalProperty $Scope 'status' '')
  $FirewallStatus = [string](Get-OptionalProperty $Firewall 'status' '')
  if ($ScopeStatus -notin @('', 'exact')) { throw 'Legacy execution scope status is contradictory.' }
  if ($FirewallStatus -notin @('', 'active')) { throw 'Legacy stage firewall status is contradictory.' }

  $WorkTransactionPath = Join-Path $Agy 'WORK_ITEM_TRANSACTION.json'
  $AuthorityTransactionPath = Join-Path $Agy 'EXECUTION_AUTHORITY_TRANSACTION.json'
  $HasWorkTransaction = Test-Path -LiteralPath $WorkTransactionPath -PathType Leaf
  $HasAuthorityTransaction = Test-Path -LiteralPath $AuthorityTransactionPath -PathType Leaf
  $NeedsAdoption = -not $HasWorkTransaction -or -not $HasAuthorityTransaction -or [string]::IsNullOrWhiteSpace($ScopeStatus) -or [string]::IsNullOrWhiteSpace($FirewallStatus) -or [string]::IsNullOrWhiteSpace($ScopeProjectRoot)
  if ($NeedsAdoption -and [string](Get-OptionalProperty $Lease 'baseline_head' '') -cne $Head) { throw 'Legacy execution lease baseline HEAD does not match the current worktree HEAD.' }
  if (-not $NeedsAdoption -and (Get-OptionalProperty $Lease 'first_write_started' $false) -ne $true -and [string](Get-OptionalProperty $Lease 'baseline_head' '') -cne $Head) { throw 'Execution lease baseline HEAD does not match the current worktree HEAD.' }
  if ([string](Get-OptionalProperty $Lease 'owner_goal_sha256' '') -cne (Get-TextSha256 $Goal)) { throw 'Legacy execution lease owner-goal fingerprint is stale.' }
  $ScopeHash = Get-Sha256 $ScopePath
  $FirewallHash = Get-Sha256 $FirewallPath
  if ([string](Get-OptionalProperty $Lease 'execution_scope_sha256' '') -cne $ScopeHash) { throw 'Legacy execution lease scope fingerprint is stale.' }

  $AllowedPaths = @((Get-OptionalProperty $Scope 'allowed_paths' @()))
  $LeaseAllowedPaths = @((Get-OptionalProperty $Lease 'allowed_paths' @()))
  if ($AllowedPaths.Count -eq 0 -or $AllowedPaths.Count -ne $LeaseAllowedPaths.Count -or ($AllowedPaths -join "`0") -cne ($LeaseAllowedPaths -join "`0")) { throw 'Legacy scope and lease allowed paths do not match exactly.' }
  $LeaseId = [string](Get-OptionalProperty $Lease 'lease_id' '')
  if ([string]::IsNullOrWhiteSpace($LeaseId)) { throw 'Legacy active lease has no lease_id.' }

  $WorkTransaction = $null
  if ($HasWorkTransaction) {
    $WorkTransaction = Get-Content -LiteralPath $WorkTransactionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string](Get-OptionalProperty $WorkTransaction 'status' '') -ne 'committed' -or [string](Get-OptionalProperty $WorkTransaction 'work_item_id' '') -ne $WorkItemId -or [int](Get-OptionalProperty $WorkTransaction 'goal_epoch' -1) -ne $GoalEpoch -or [string]::IsNullOrWhiteSpace([string](Get-OptionalProperty $WorkTransaction 'transaction_id' ''))) { throw 'Existing work-item transaction is not committed and identity-matching.' }
  }
  $AuthorityTransaction = $null
  if ($HasAuthorityTransaction) {
    $AuthorityTransaction = Get-Content -LiteralPath $AuthorityTransactionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $AuthorityFiles = Get-OptionalProperty $AuthorityTransaction 'files'
    $AuthorityScope = Get-OptionalProperty $AuthorityFiles 'EXECUTION_SCOPE.json'
    $AuthorityFirewall = Get-OptionalProperty $AuthorityFiles 'STAGE_FIREWALL.json'
    if ([string](Get-OptionalProperty $AuthorityTransaction 'status' '') -ne 'committed' -or [string](Get-OptionalProperty $AuthorityTransaction 'work_item_id' '') -ne $WorkItemId -or [int](Get-OptionalProperty $AuthorityTransaction 'goal_epoch' -1) -ne $GoalEpoch -or [string](Get-OptionalProperty $AuthorityTransaction 'lease_id' '') -ne $LeaseId -or [string](Get-OptionalProperty $AuthorityScope 'sha256' '') -cne $ScopeHash -or [string](Get-OptionalProperty $AuthorityFirewall 'sha256' '') -cne $FirewallHash) { throw 'Existing execution-authority transaction is not committed and identity-matching.' }
  }

  return [pscustomobject]@{
    work_item = $WorkItem; scope = $Scope; lease = $Lease; firewall = $Firewall
    work_transaction = $WorkTransaction; authority_transaction = $AuthorityTransaction
    work_item_id = $WorkItemId; goal_epoch = $GoalEpoch; lease_id = $LeaseId
    allowed_paths = $AllowedPaths; branch = $Branch; head = $Head; needs_adoption = $NeedsAdoption
  }
}

$ProjectSlug = ([IO.Path]::GetFileName($Project) -replace '[^A-Za-z0-9._-]', '_')
$BackupBaseFull = [IO.Path]::GetFullPath($BackupBaseRoot).TrimEnd($PathSeparators)
$TransactionId = 'runtime-1.2.16-' + [Guid]::NewGuid().ToString('N')
$BackupRoot = Join-Path $BackupBaseFull (Join-Path $ProjectSlug $TransactionId)
$JournalPath = Join-Path $BackupRoot 'journal.json'
$LockRoot = Join-Path $BackupBaseFull '.locks'
$LockPath = Join-Path $LockRoot ((Get-TextSha256 $Project).Substring(0, 24) + '.lock')
$LockStream = $null
$LockOwned = $false
$RetainLock = $false
$BackupIndex = New-Object System.Collections.Generic.List[object]
$DirectoryBaseline = @{}
$MutationStarted = $false
$JournalWritten = $false
$CreatedOrReplaced = New-Object System.Collections.Generic.List[string]
$Skipped = New-Object System.Collections.Generic.List[string]
$WriteCount = 0

function Assert-BackupConfined([string]$Path, [string]$Description) {
  $Full = [IO.Path]::GetFullPath($Path)
  if (-not $Full.StartsWith($BackupBaseFull + [IO.Path]::DirectorySeparatorChar, $PathComparison)) { throw "$Description escapes the runtime backup root." }
  return $Full
}

function Read-LockMetadata([IO.FileStream]$Stream) {
  $Stream.Position = 0
  $Reader = [IO.StreamReader]::new($Stream, [Text.Encoding]::UTF8, $true, 1024, $true)
  try { $Text = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
  if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Stale runtime lock has no recovery metadata.' }
  try { return $Text | ConvertFrom-Json } catch { throw 'Stale runtime lock metadata is invalid.' }
}

function Write-LockMetadata([IO.FileStream]$Stream, [object]$Metadata) {
  $Bytes = $Utf8NoBom.GetBytes(($Metadata | ConvertTo-Json -Depth 20))
  $Stream.SetLength(0); $Stream.Position = 0
  $Stream.Write($Bytes, 0, $Bytes.Length)
  $Stream.Flush($true)
}

function Restore-StaleJournal([object]$Journal, [string]$StaleBackupRoot, [string]$StaleJournalPath) {
  if ([string](Get-OptionalProperty $Journal 'project_root' '') -eq '' -or -not (Test-SamePath ([string]$Journal.project_root) $Project)) { throw 'Stale runtime journal belongs to a different project.' }
  $Phase = [string](Get-OptionalProperty $Journal 'phase' '')
  if ($Phase -in @('committed', 'rolled_back')) { Write-Warning "Cleaned stale $Phase runtime lock without changing the project."; return }
  if ($Phase -ne 'backed_up') { throw "Stale runtime journal has unsupported recovery phase: $Phase" }

  foreach ($Entry in @((Get-OptionalProperty $Journal 'paths' @())) | Sort-Object { ([string]$_.relative).Length } -Descending) {
    $Relative = Normalize-Relative ([string]$Entry.relative)
    if (-not $FrameworkSet.ContainsKey($Relative.ToLowerInvariant())) { throw "Stale runtime journal contains a path outside the framework allowlist: $Relative" }
    $Destination = Resolve-ConfinedPath -Root $Project -Relative $Relative
    if ((Get-OptionalProperty $Entry 'existed' $false) -eq $true) {
      $Backup = Resolve-ConfinedPath -Root $StaleBackupRoot -Relative ('files/' + $Relative)
      if (-not (Test-Path -LiteralPath $Backup -PathType Leaf)) { throw "Stale runtime backup is missing: $Relative" }
      $Expected = [string](Get-OptionalProperty $Entry 'sha256' '')
      if ($Expected -notmatch '^[0-9a-fA-F]{64}$' -or (Get-Sha256 $Backup) -cne $Expected.ToLowerInvariant()) { throw "Stale runtime backup hash mismatch: $Relative" }
      Write-BytesAtomic -Path $Destination -Bytes ([IO.File]::ReadAllBytes($Backup))
    }
    elseif (Test-Path -LiteralPath $Destination -PathType Leaf) { Remove-Item -LiteralPath $Destination -Force }
  }
  foreach ($DirectoryEntry in @((Get-OptionalProperty $Journal 'directories' @())) | Sort-Object { ([string]$_.relative).Length } -Descending) {
    if ((Get-OptionalProperty $DirectoryEntry 'existed' $false) -eq $true) { continue }
    $Relative = Normalize-Relative ([string]$DirectoryEntry.relative)
    $Directory = Resolve-ConfinedPath -Root $Project -Relative $Relative
    if ((Test-Path -LiteralPath $Directory -PathType Container) -and $null -eq (Get-ChildItem -LiteralPath $Directory -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $Directory -Force }
  }
  Set-JsonProperty $Journal 'phase' 'rolled_back'
  Set-JsonProperty $Journal 'recovered_at_utc' ((Get-Date).ToUniversalTime().ToString('o'))
  Write-JsonAtomic -Path $StaleJournalPath -Value $Journal -Depth 40
  Write-Warning "Recovered interrupted runtime transaction from: $StaleBackupRoot"
}

try {
  New-Item -ItemType Directory -Force -Path $LockRoot | Out-Null
  $StaleLock = $false
  try { $LockStream = [IO.File]::Open($LockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
  catch {
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { throw "Unable to create runtime transaction lock: $LockPath" }
    try { $LockStream = [IO.File]::Open($LockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None); $StaleLock = $true }
    catch { throw "Another runtime transaction is active for this project: $LockPath" }
  }
  $LockOwned = $true
  if ($StaleLock) {
    try {
      if ($LockStream.Length -eq 0) {
        Write-Warning 'Recovered an empty stale pre-mutation runtime lock.'
      }
      else {
        $StaleMetadata = Read-LockMetadata $LockStream
        if ([string](Get-OptionalProperty $StaleMetadata 'project_root' '') -eq '' -or -not (Test-SamePath ([string]$StaleMetadata.project_root) $Project)) { throw 'Stale runtime lock belongs to a different project.' }
        $StaleBackupRoot = Assert-BackupConfined ([string](Get-OptionalProperty $StaleMetadata 'backup_root' '')) 'Stale backup root'
        $StaleJournalPath = Assert-BackupConfined ([string](Get-OptionalProperty $StaleMetadata 'journal_path' '')) 'Stale journal path'
        if (-not (Test-SamePath $StaleJournalPath (Join-Path $StaleBackupRoot 'journal.json'))) { throw 'Stale runtime lock journal path is inconsistent.' }
        if (Test-Path -LiteralPath $StaleJournalPath -PathType Leaf) {
          $StaleJournal = Get-Content -LiteralPath $StaleJournalPath -Raw -Encoding UTF8 | ConvertFrom-Json
          Restore-StaleJournal -Journal $StaleJournal -StaleBackupRoot $StaleBackupRoot -StaleJournalPath $StaleJournalPath
        }
        elseif ([string](Get-OptionalProperty $StaleMetadata 'phase' '') -ne 'planning') { throw 'Stale runtime lock has no recoverable journal.' }
        else { Write-Warning 'Cleaned a stale pre-mutation runtime lock.' }
      }
    }
    catch { $RetainLock = $true; throw }
  }
  Write-LockMetadata -Stream $LockStream -Metadata ([ordered]@{ schema_version = '1.0.0'; phase = 'planning'; project_root = $Project; transaction_id = $TransactionId; backup_root = $BackupRoot; journal_path = $JournalPath; created_at_utc = (Get-Date).ToUniversalTime().ToString('o') })

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
$LegacyFindingsPreflight = Test-LegacyFindingsPreconditions
$LegacyAuthorityPreflight = Test-LegacyAuthorityPreconditions

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
$AlreadyCurrent = $AllFilesCurrent -and ($SkipActiveWorkItemMigration -or $MigrationCurrent) -and $ReceiptsCurrent -and -not [bool]$LegacyFindingsPreflight.requires_migration

$Summary = [ordered]@{ schema_version = '1.0.0'; ecosystem_version = $EcosystemVersion; source_commit = $SourceCommit; asset_sha256 = if ($AssetSha256) { $AssetSha256.ToLowerInvariant() } else { $null }; project_root = $Project; apply = [bool]$Apply; already_current = $AlreadyCurrent; product_baseline_sha256 = $ProductBeforeIdentity; legacy_findings_migration = [ordered]@{ required = [bool]$LegacyFindingsPreflight.requires_migration; source_sha256 = $LegacyFindingsPreflight.source_sha256; archive_path = $LegacyFindingsArchiveRelative }; plan = $Plan.ToArray() }
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
  Write-Host 'PROJECT RUNTIME 1.2.16 ALREADY CURRENT; VERIFICATION-ONLY RUN PASSED.' -ForegroundColor Green
  return
}

function Backup-Path([string]$Relative) {
  $Normalized = Normalize-Relative $Relative
  if (@($BackupIndex | Where-Object { $_.relative -eq $Normalized }).Count -gt 0) { return }
  $Destination = Resolve-ConfinedPath -Root $Project -Relative $Normalized
  $Directory = Split-Path -Parent $Destination
  while ($Directory.Length -gt $Project.Length -and $Directory.StartsWith($Project + [IO.Path]::DirectorySeparatorChar, $PathComparison)) {
    if (-not $DirectoryBaseline.ContainsKey($Directory)) { $DirectoryBaseline[$Directory] = Test-Path -LiteralPath $Directory -PathType Container }
    $Directory = Split-Path -Parent $Directory
  }
  $Entry = [ordered]@{ relative = $Normalized; existed = (Test-Path -LiteralPath $Destination -PathType Leaf); sha256 = $null; backup = $null }
  if ($Entry.existed) {
    $Entry.sha256 = Get-Sha256 $Destination
    $BackupRelative = $Normalized.Replace([char]'/', [IO.Path]::DirectorySeparatorChar)
    $Entry.backup = Join-Path (Join-Path $BackupRoot 'files') $BackupRelative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Entry.backup) | Out-Null
    Copy-Item -LiteralPath $Destination -Destination $Entry.backup -Force
  }
  [void]$BackupIndex.Add([pscustomobject]$Entry)
}

function Get-DirectoryJournalRows {
  return @($DirectoryBaseline.Keys | ForEach-Object {
    [pscustomobject]@{ relative = $_.Substring($Project.Length).TrimStart($PathSeparators).Replace('\', '/'); existed = [bool]$DirectoryBaseline[$_] }
  } | Sort-Object relative)
}

function Write-CurrentJournal([string]$Phase, [string]$ProductAfterIdentity = '') {
  $Value = [ordered]@{
    schema_version = '1.1.0'; transaction_id = $TransactionId; phase = $Phase
    source_commit = $SourceCommit; project_root = $Project
    product_baseline_before_sha256 = $ProductBeforeIdentity
    paths = $BackupIndex.ToArray(); directories = @(Get-DirectoryJournalRows)
  }
  if (-not [string]::IsNullOrWhiteSpace($ProductAfterIdentity)) { $Value.product_baseline_after_sha256 = $ProductAfterIdentity }
  Write-JsonAtomic -Path $JournalPath -Value $Value -Depth 40
}

function Restore-Transaction {
  foreach ($Entry in @($BackupIndex.ToArray() | Sort-Object { $_.relative.Length } -Descending)) {
    $Destination = Resolve-ConfinedPath -Root $Project -Relative $Entry.relative
    if ($Entry.existed) { Write-BytesAtomic -Path $Destination -Bytes ([IO.File]::ReadAllBytes([string]$Entry.backup)) }
    elseif (Test-Path -LiteralPath $Destination -PathType Leaf) { Remove-Item -LiteralPath $Destination -Force }
  }
  foreach ($Directory in @($DirectoryBaseline.Keys | Where-Object { -not $DirectoryBaseline[$_] } | Sort-Object Length -Descending)) {
    if ((Test-Path -LiteralPath $Directory -PathType Container) -and $null -eq (Get-ChildItem -LiteralPath $Directory -Force | Select-Object -First 1)) {
      Remove-Item -LiteralPath $Directory -Force
    }
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
  $LegacyFindingsApplyPreflight = Test-LegacyFindingsPreconditions
  if ([string]$LegacyFindingsApplyPreflight.state -cne [string]$LegacyFindingsPreflight.state -or [string]$LegacyFindingsApplyPreflight.source_sha256 -cne [string]$LegacyFindingsPreflight.source_sha256) { throw 'FINDINGS.json changed after preflight; refusing to deploy.' }
  $LegacyAuthorityPreflight = Test-LegacyAuthorityPreconditions
  New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
  foreach ($Relative in @($Map.target) + $ConditionalState | Sort-Object -Unique) { Backup-Path $Relative }
  Write-CurrentJournal -Phase 'backed_up'
  $JournalWritten = $true

  foreach ($Item in @($Map | Where-Object { $_.mode -ne 'activate_last' })) { Copy-MapItem $Item }

  if ([bool]$LegacyFindingsApplyPreflight.requires_migration) {
    $FindingsPath = Resolve-ConfinedPath -Root $Project -Relative $FindingsRelative
    if ((Get-Sha256 $FindingsPath) -cne [string]$LegacyFindingsApplyPreflight.source_sha256) { throw 'Legacy FINDINGS.json changed before migration.' }
    $ArchivePath = Resolve-ConfinedPath -Root $Project -Relative $LegacyFindingsArchiveRelative
    if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
      if ((Get-Sha256 $ArchivePath) -cne [string]$LegacyFindingsApplyPreflight.source_sha256) { throw 'Existing legacy FINDINGS.json history archive conflicts with the migration source.' }
    }
    else {
      $MutationStarted = $true
      Write-BytesAtomic -Path $ArchivePath -Bytes ([byte[]]$LegacyFindingsApplyPreflight.source_bytes)
      [void]$CreatedOrReplaced.Add($LegacyFindingsArchiveRelative)
    }
    if ((Get-Sha256 $ArchivePath) -cne [string]$LegacyFindingsApplyPreflight.source_sha256) { throw 'Legacy FINDINGS.json history archive is not byte-identical to the migration source.' }
    $MutationStarted = $true
    Write-JsonAtomic -Path $FindingsPath -Value $LegacyFindingsApplyPreflight.migrated_document -Depth 40
    [void]$CreatedOrReplaced.Add($FindingsRelative)
    $MigratedState = Test-LegacyFindingsPreconditions
    if ([string]$MigratedState.state -cne 'canonical' -or [bool]$MigratedState.requires_migration) { throw 'Migrated FINDINGS.json did not pass canonical validation.' }
  }

  if (-not $SkipActiveWorkItemMigration) {
    $Agy = Join-Path $Project '.agy'
    $WorkItemPath = Join-Path $Agy 'WORK_ITEM.json'
    if (Test-Path -LiteralPath $WorkItemPath -PathType Leaf) {
      $LegacyAuthority = Test-LegacyAuthorityPreconditions
      if ($null -eq $LegacyAuthority) { throw 'Active legacy authority preflight did not return an adoption candidate.' }
      $MutationStarted = $true
      $WorkItem = $LegacyAuthority.work_item
      $Scope = $LegacyAuthority.scope
      $Lease = $LegacyAuthority.lease
      $Firewall = $LegacyAuthority.firewall
      $WorkItemId = [string]$LegacyAuthority.work_item_id
      $GoalEpoch = [int]$LegacyAuthority.goal_epoch
      $LeaseId = [string]$LegacyAuthority.lease_id
      $AllowedPaths = @($LegacyAuthority.allowed_paths)
      $Branch = [string]$LegacyAuthority.branch
      $Head = [string]$LegacyAuthority.head
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
      Set-JsonProperty $Scope 'status' 'exact'; Set-JsonProperty $Scope 'project_root' $Project; Set-JsonProperty $Scope 'route' $Route
      Write-JsonAtomic $ScopePath $Scope
      $ScopeHash = Get-Sha256 $ScopePath

      Set-JsonProperty $Lease 'status' 'active'; Set-JsonProperty $Lease 'project_root' $Project; Set-JsonProperty $Lease 'worktree_root' $Project; Set-JsonProperty $Lease 'branch' $Branch
      Set-JsonProperty $Lease 'owner_goal_sha256' (Get-TextSha256 ([string]$WorkItem.goal)); Set-JsonProperty $Lease 'execution_scope_sha256' $ScopeHash; Set-JsonProperty $Lease 'allowed_paths' $AllowedPaths; Set-JsonProperty $Lease 'route' $Route
      Write-JsonAtomic $LeasePath $Lease

      Set-JsonProperty $Firewall 'status' 'active'; Set-JsonProperty $Firewall 'work_item_id' $WorkItemId
      if ($null -eq $Firewall.PSObject.Properties['protected_path_patterns']) { Set-JsonProperty $Firewall 'protected_path_patterns' $AllowedPaths }
      $AlgorithmAuthorized = [string](Get-OptionalProperty $Firewall 'active_sub_scope' '') -eq 'algorithm_repair'
      Set-JsonProperty $Firewall 'algorithm_repair_authorized' $AlgorithmAuthorized
      Write-JsonAtomic $FirewallPath $Firewall

      $WorkTransactionPath = Join-Path $Agy 'WORK_ITEM_TRANSACTION.json'
      $WorkTransaction = if ($null -ne $LegacyAuthority.work_transaction) { $LegacyAuthority.work_transaction } else { [pscustomobject]@{} }
      Set-JsonProperty $WorkTransaction 'schema_version' '1.1.0'; Set-JsonProperty $WorkTransaction 'status' 'committed'
      if ([string]::IsNullOrWhiteSpace([string](Get-OptionalProperty $WorkTransaction 'transaction_id' ''))) { Set-JsonProperty $WorkTransaction 'transaction_id' ('adopted-work-item-' + (Get-TextSha256 $WorkItemId).Substring(0, 20)) }
      Set-JsonProperty $WorkTransaction 'work_item_id' $WorkItemId; Set-JsonProperty $WorkTransaction 'goal_epoch' $GoalEpoch; Set-JsonProperty $WorkTransaction 'committed_at_utc' (Get-OptionalProperty $WorkTransaction 'committed_at_utc' $MigrationTime)
      Write-JsonAtomic $WorkTransactionPath $WorkTransaction

      $AuthorityTransaction = if ($null -ne $LegacyAuthority.authority_transaction) { $LegacyAuthority.authority_transaction } else { [pscustomobject]@{} }
      Set-JsonProperty $AuthorityTransaction 'schema_version' '1.1.0'; Set-JsonProperty $AuthorityTransaction 'status' 'committed'
      if ([string]::IsNullOrWhiteSpace([string](Get-OptionalProperty $AuthorityTransaction 'transaction_id' ''))) { Set-JsonProperty $AuthorityTransaction 'transaction_id' ('adopted-authority-' + (Get-TextSha256 $LeaseId).Substring(0, 20)) }
      Set-JsonProperty $AuthorityTransaction 'work_item_id' $WorkItemId; Set-JsonProperty $AuthorityTransaction 'goal_epoch' $GoalEpoch; Set-JsonProperty $AuthorityTransaction 'lease_id' $LeaseId; Set-JsonProperty $AuthorityTransaction 'branch' $Branch; Set-JsonProperty $AuthorityTransaction 'baseline_head' ([string](Get-OptionalProperty $Lease 'baseline_head' $Head)); Set-JsonProperty $AuthorityTransaction 'route' $Route
      Set-JsonProperty $AuthorityTransaction 'files' ([ordered]@{ 'EXECUTION_SCOPE.json' = [ordered]@{ sha256 = Get-Sha256 $ScopePath }; 'STAGE_FIREWALL.json' = [ordered]@{ sha256 = Get-Sha256 $FirewallPath } })
      Set-JsonProperty $AuthorityTransaction 'committed_at_utc' (Get-OptionalProperty $AuthorityTransaction 'committed_at_utc' $MigrationTime)
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

  if ($FaultInjectionAfterMigration) { throw 'Injected runtime update failure after migration.' }

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
  Write-CurrentJournal -Phase 'committed' -ProductAfterIdentity $ProductAfterIdentity
  Write-Host 'PROJECT RUNTIME 1.2.16 UPDATE COMPLETED.' -ForegroundColor Green
}
catch {
  $Failure = $_
  if ($JournalWritten) {
    try {
      Write-Warning 'Runtime update failed. Restoring every journaled framework-owned path.'
      Restore-Transaction
      Write-CurrentJournal -Phase 'rolled_back'
      Write-Warning "Rollback completed from: $BackupRoot"
    }
    catch {
      $RetainLock = $true
      throw "Runtime rollback failed and the recovery lock was retained. Original failure: $($Failure.Exception.Message). Rollback failure: $($_.Exception.Message)"
    }
  }
  throw $Failure
}
}
finally {
  if ($null -ne $LockStream) { $LockStream.Dispose() }
  if ($LockOwned -and -not $RetainLock) { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue }
}
