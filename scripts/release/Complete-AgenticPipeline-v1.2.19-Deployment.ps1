[CmdletBinding()]
param(
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [Parameter(Mandatory = $true)][string]$ProjectRoot,
  [Parameter(Mandatory = $true)][string]$RuntimeAsset,
  [Parameter(Mandatory = $true)][string]$ActionBridgeAsset,
  [Parameter(Mandatory = $true)][string]$ContextHandoffAsset,
  [Parameter(Mandatory = $true)][string]$CompanionAsset,
  [Parameter(Mandatory = $true)][string]$HandoffArchive,
  [string]$ProjectId = '',
  [string]$LogicalName = '',
  [string]$HandoffRoot = 'C:\Scripts\AntigravityProjects\companion-handoff',
  [string]$DeploymentRoot = '',
  [string]$RuntimeBackupRoot = "$env:USERPROFILE\Documents\antigravity\pipeline-maintenance\runtime-backups",
  [switch]$OpenFolder
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$EcosystemVersion = '1.2.19'

$Repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Leaf = Split-Path -Leaf $Project
if ([string]::IsNullOrWhiteSpace($LogicalName)) { $LogicalName = $Leaf }
if ([string]::IsNullOrWhiteSpace($ProjectId)) { $ProjectId = ($Leaf -replace '[^A-Za-z0-9._-]', '-').Trim('-') }
if ($ProjectId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $ProjectId -in @('.', '..')) { throw 'ProjectId must be one safe filename component.' }
if ([string]::IsNullOrWhiteSpace($DeploymentRoot)) {
  $DeploymentRoot = Join-Path $env:USERPROFILE (Join-Path 'Documents\antigravity\companion-deployments' (Join-Path $ProjectId $EcosystemVersion))
}

. (Join-Path $Repo 'scripts\windows\common\NativeProcess.ps1')
$Version = Get-Content -LiteralPath (Join-Path $Repo 'VERSION.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($Field in @('ecosystem_version','package_version','runtime_version','companion_version','action_bridge_version','context_handoff_version')) {
  if ([string]$Version.$Field -ne $EcosystemVersion) { throw "Canonical version mismatch: $Field" }
}
$HeadResult = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Repo,'rev-parse','HEAD')
Assert-AgenticNativeSuccess -Result $HeadResult -Description 'canonical HEAD'
$SourceCommit = $HeadResult.StdOut.Trim()
$StatusResult = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Repo,'status','--porcelain=v2','-z','--untracked-files=all')
Assert-AgenticNativeSuccess -Result $StatusResult -Description 'canonical status'
if ($StatusResult.StdOut.Length -gt 0) { throw 'Complete deployment requires a clean canonical source commit.' }

$Assets = [ordered]@{
  runtime = (Resolve-Path -LiteralPath $RuntimeAsset).Path
  action_bridge = (Resolve-Path -LiteralPath $ActionBridgeAsset).Path
  context_handoff = (Resolve-Path -LiteralPath $ContextHandoffAsset).Path
  companion = (Resolve-Path -LiteralPath $CompanionAsset).Path
  handoff_archive = (Resolve-Path -LiteralPath $HandoffArchive).Path
}
foreach ($Entry in $Assets.GetEnumerator()) {
  if (-not (Test-Path -LiteralPath $Entry.Value -PathType Leaf) -or [IO.Path]::GetExtension($Entry.Value) -ne '.zip') { throw "Required ZIP is missing: $($Entry.Key)" }
}

function Test-SafeZip([string]$Path) {
  $Archive = [IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $Names = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($Entry in $Archive.Entries) {
      $Name = $Entry.FullName.Replace('\','/')
      if ([string]::IsNullOrWhiteSpace($Name) -or $Name.StartsWith('/') -or $Name -match '^[A-Za-z]:' -or $Name -match '(^|/)\.\.(/|$)' -or -not $Names.Add($Name)) {
        throw "Unsafe or duplicate ZIP member in $Path"
      }
    }
  }
  finally { $Archive.Dispose() }
}

function Find-PackageRoot([string]$ExtractRoot,[string]$Marker) {
  $PackageRootMatches = @(Get-ChildItem -LiteralPath $ExtractRoot -Recurse -File -Filter $Marker | ForEach-Object { Split-Path -Parent $_.FullName } | Sort-Object -Unique)
  if ($PackageRootMatches.Count -ne 1) { throw "Expected exactly one $Marker package root; found $($PackageRootMatches.Count)." }
  return $PackageRootMatches[0]
}

$TempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$OperationRoot = Join-Path $TempBase ('agentic-complete-deployment-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $OperationRoot | Out-Null
try {
  foreach ($Entry in $Assets.GetEnumerator()) { Test-SafeZip $Entry.Value }

  $RuntimeExtract = Join-Path $OperationRoot 'runtime'
  $BridgeExtract = Join-Path $OperationRoot 'bridge'
  $HandoffExtract = Join-Path $OperationRoot 'handoff'
  Expand-Archive -LiteralPath $Assets.runtime -DestinationPath $RuntimeExtract
  Expand-Archive -LiteralPath $Assets.action_bridge -DestinationPath $BridgeExtract
  Expand-Archive -LiteralPath $Assets.context_handoff -DestinationPath $HandoffExtract

  $RuntimePackage = Find-PackageRoot -ExtractRoot $RuntimeExtract -Marker 'RUNTIME_OVERLAY_MANIFEST.json'
  $RuntimeUpdater = Join-Path $RuntimePackage 'scripts\windows\Update-AgenticProjectRuntime-v1.2.19.ps1'
  $RuntimeHash = (Get-FileHash -LiteralPath $Assets.runtime -Algorithm SHA256).Hash.ToLowerInvariant()
  $RuntimeArguments = @{
    ProjectRoot = $Project
    RuntimeRoot = $RuntimePackage
    RuntimeArchivePath = $Assets.runtime
    AssetSha256 = $RuntimeHash
    ExpectedSourceCommit = $SourceCommit
    AllowDirty = $true
    BackupBaseRoot = $RuntimeBackupRoot
  }
  & $RuntimeUpdater @RuntimeArguments
  $RuntimeArguments.Apply = $true
  & $RuntimeUpdater @RuntimeArguments
  & $RuntimeUpdater @RuntimeArguments

  $BridgePackage = Find-PackageRoot -ExtractRoot $BridgeExtract -Marker 'Install-CompanionActionBridge.ps1'
  $BridgeInstaller = Join-Path $BridgePackage 'Install-CompanionActionBridge.ps1'
  $BridgeHash = (Get-FileHash -LiteralPath $Assets.action_bridge -Algorithm SHA256).Hash.ToLowerInvariant()
  & $BridgeInstaller -ProjectRoot $Project -ProjectId $ProjectId -LogicalName $LogicalName -ExpectedSourceCommit $SourceCommit -PackageArchivePath $Assets.action_bridge -AssetSha256 $BridgeHash
  & $BridgeInstaller -ProjectRoot $Project -ProjectId $ProjectId -LogicalName $LogicalName -ExpectedSourceCommit $SourceCommit -PackageArchivePath $Assets.action_bridge -AssetSha256 $BridgeHash -Apply
  & $BridgeInstaller -ProjectRoot $Project -ProjectId $ProjectId -LogicalName $LogicalName -ExpectedSourceCommit $SourceCommit -PackageArchivePath $Assets.action_bridge -AssetSha256 $BridgeHash -Apply

  $HandoffPackage = Find-PackageRoot -ExtractRoot $HandoffExtract -Marker 'Update-AgenticContextHandoff-v1.2.19.ps1'
  $HandoffUpdater = Join-Path $HandoffPackage 'Update-AgenticContextHandoff-v1.2.19.ps1'
  $HandoffHash = (Get-FileHash -LiteralPath $Assets.context_handoff -Algorithm SHA256).Hash.ToLowerInvariant()
  $HandoffArguments = @{
    PackageRoot = $HandoffPackage
    PackageArchivePath = $Assets.context_handoff
    AssetSha256 = $HandoffHash
    ExpectedSourceCommit = $SourceCommit
    HandoffRoot = $HandoffRoot
  }
  & $HandoffUpdater @HandoffArguments
  $HandoffArguments.Apply = $true
  & $HandoffUpdater @HandoffArguments
  & $HandoffUpdater @HandoffArguments

  $CompanionHash = (Get-FileHash -LiteralPath $Assets.companion -Algorithm SHA256).Hash.ToLowerInvariant()
  $Prepare = Join-Path $Repo 'scripts\release\Prepare-AgenticPipeline-Companion-v1.2.19.ps1'
  & $Prepare -CompanionZip $Assets.companion -OutputRoot $DeploymentRoot -CanonicalRepo $Repo -ExpectedAssetSha256 $CompanionHash -ExpectedSourceCommit $SourceCommit -Force
  & $Prepare -CompanionZip $Assets.companion -OutputRoot $DeploymentRoot -CanonicalRepo $Repo -ExpectedAssetSha256 $CompanionHash -ExpectedSourceCommit $SourceCommit -Force

  $DeploymentManifest = Join-Path ([IO.Path]::GetFullPath($DeploymentRoot)) 'DEPLOYMENT_MANIFEST.json'
  $Bootstrap = Join-Path $Repo 'scripts\release\Create-Companion-Restart-Bootstrap-v1.2.19.ps1'
  $BootstrapArguments = @{
    ProjectRoot = $Project
    PipelineRepo = $Repo
    OutputRoot = $DeploymentRoot
    HandoffArchive = $Assets.handoff_archive
    CompanionAsset = $Assets.companion
    DeploymentManifest = $DeploymentManifest
    LogicalName = $LogicalName
    ProjectId = $ProjectId
  }
  & $Bootstrap @BootstrapArguments
  & $Bootstrap @BootstrapArguments -OpenFolder:$OpenFolder

  Write-Host 'PROJECT RUNTIME / ACTION BRIDGE / CONTEXT HANDOFF / COMPANION DEPLOYMENT: PASS' -ForegroundColor Green
}
finally {
  if (Test-Path -LiteralPath $OperationRoot) {
    $ResolvedOperation = (Resolve-Path -LiteralPath $OperationRoot).Path
    if (-not $ResolvedOperation.StartsWith($TempBase + '\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $ResolvedOperation) -notlike 'agentic-complete-deployment-*') {
      throw "Refusing unsafe temporary cleanup: $ResolvedOperation"
    }
    Remove-Item -LiteralPath $ResolvedOperation -Recurse -Force
  }
}
