[CmdletBinding()]
param(
  [string]$InstallRoot = "$env:LOCALAPPDATA\AgenticPipeline\ActionBridge",
  [string]$RegistryPath = "$env:USERPROFILE\.agentic-pipeline\project-registry.json",
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$ProjectId = '',
  [string]$LogicalName = '',
  [string]$ExpectedSourceCommit = '',
  [string]$AssetSha256 = '',
  [switch]$Apply
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Python = Get-Command pythonw -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $Python) { $Python = Get-Command python -ErrorAction Stop | Select-Object -First 1 }
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { throw "Project root is missing: $ProjectRoot" }
$ResolvedProject = (Resolve-Path -LiteralPath $ProjectRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $ResolvedProject '.agy') -PathType Container) -or -not (Test-Path -LiteralPath (Join-Path $ResolvedProject '.agents') -PathType Container)) { throw 'Project is not an installed Agentic Pipeline project.' }
$InstalledManifestPath=Join-Path $ResolvedProject '.agy\INSTALLATION_MANIFEST.json'
if(-not(Test-Path -LiteralPath $InstalledManifestPath -PathType Leaf)){throw 'Project installation manifest is missing.'}
$InstalledManifest=Get-Content -LiteralPath $InstalledManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$InstalledManifest.package_version-ne'1.2.9'-or[string]$InstalledManifest.runtime_version-ne'1.2.9'){throw 'Action Bridge requires an installed project runtime 1.2.9.'}
$Leaf = Split-Path -Leaf $ResolvedProject
if ([string]::IsNullOrWhiteSpace($LogicalName)) { $LogicalName = $Leaf }
if ([string]::IsNullOrWhiteSpace($ProjectId)) {
  $ProjectId = ($Leaf -replace '[^A-Za-z0-9._-]','-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw 'ProjectId cannot be derived. Supply -ProjectId explicitly.' }
}
if ($ProjectId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $ProjectId -in @('.', '..')) { throw 'ProjectId must be one safe identifier component.' }
$Source = Join-Path $PSScriptRoot 'companion_action_bridge.py'
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Bridge source is missing: $Source" }
$PackageVersionPath=Join-Path $PSScriptRoot 'VERSION.json'
$PackageManifestPath=Join-Path $PSScriptRoot 'MANIFEST.json'
if(-not(Test-Path -LiteralPath $PackageVersionPath -PathType Leaf)-or-not(Test-Path -LiteralPath $PackageManifestPath -PathType Leaf)){throw 'Action Bridge package identity files are missing.'}
$PackageVersion=Get-Content -LiteralPath $PackageVersionPath -Raw -Encoding UTF8|ConvertFrom-Json
$PackageManifest=Get-Content -LiteralPath $PackageManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$PackageVersion.ecosystem_version-ne'1.2.9'-or[string]$PackageManifest.ecosystem_version-ne'1.2.9'-or[string]$PackageVersion.source_commit-ne[string]$PackageManifest.source_commit){throw 'Action Bridge package version/source identity is inconsistent.'}
if([string]$PackageManifest.source_commit-notmatch'^[0-9a-f]{40}$'){throw 'Action Bridge package source commit is invalid.'}
if(-not[string]::IsNullOrWhiteSpace($ExpectedSourceCommit)-and[string]$PackageManifest.source_commit-ne$ExpectedSourceCommit){throw 'Action Bridge package source commit does not match ExpectedSourceCommit.'}
if(-not[string]::IsNullOrWhiteSpace($AssetSha256)-and$AssetSha256-notmatch'^[0-9a-fA-F]{64}$'){throw 'Action Bridge asset SHA-256 is invalid.'}
foreach($Entry in @($PackageManifest.files)){$Member=Join-Path $PSScriptRoot ([string]$Entry.path);if(-not(Test-Path -LiteralPath $Member -PathType Leaf)){throw "Package member missing: $($Entry.path)"};if((Get-FileHash -LiteralPath $Member -Algorithm SHA256).Hash.ToLowerInvariant()-ne[string]$Entry.sha256){throw "Package member hash mismatch: $($Entry.path)"}}
$CapabilityPath = Join-Path $ResolvedProject '.agy\ACTION_BRIDGE_CAPABILITY.json'
$CapabilityToken = $null
if (Test-Path -LiteralPath $CapabilityPath -PathType Leaf) {
  $ExistingCapability = Get-Content -LiteralPath $CapabilityPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$ExistingCapability.project_id -eq $ProjectId -and [string]$ExistingCapability.capability_token -match '^[0-9a-f]{64}$') { $CapabilityToken = [string]$ExistingCapability.capability_token }
}
if (-not $CapabilityToken -and (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
  $ExistingRegistry = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $ExistingRegistration = @($ExistingRegistry.projects | Where-Object { [string]$_.project_id -eq $ProjectId }) | Select-Object -First 1
  if ($ExistingRegistration -and [string]$ExistingRegistration.capability_token -match '^[0-9a-f]{64}$') { $CapabilityToken = [string]$ExistingRegistration.capability_token }
}
if (-not $CapabilityToken) {
  $Bytes = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Fill($Bytes)
  $CapabilityToken = ([Convert]::ToHexString($Bytes)).ToLowerInvariant()
}
if (-not $Apply) {
  Write-Host "DRY RUN: install Companion Action Bridge to $InstallRoot"
  Write-Host "Register: $ProjectId -> $ResolvedProject"
  Write-Host 'A project capability will be preserved or generated.'
  return
}
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
Copy-Item -LiteralPath $Source -Destination (Join-Path $InstallRoot 'companion_action_bridge.py') -Force
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $RegistryPath) | Out-Null
$Registry = if (Test-Path -LiteralPath $RegistryPath -PathType Leaf) { Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{schema_version='1.2.9';ecosystem_version='1.2.9';projects=@()} }
$Projects = New-Object System.Collections.Generic.List[object]
foreach ($Item in @($Registry.projects)) { if ([string]$Item.project_id -ne $ProjectId) { [void]$Projects.Add($Item) } }
[void]$Projects.Add([ordered]@{project_id=$ProjectId;project_root=$ResolvedProject;logical_name=$LogicalName;ecosystem_version='1.2.9';capability_token=$CapabilityToken})
$NewRegistry = [ordered]@{schema_version='1.2.9';ecosystem_version='1.2.9';projects=[object[]]$Projects.ToArray()}
$Utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($RegistryPath,($NewRegistry|ConvertTo-Json -Depth 20),$Utf8)
$Capability = [ordered]@{schema_version='1.2.9';ecosystem_version='1.2.9';project_id=$ProjectId;capability_token=$CapabilityToken;purpose='companion_action_packet_import';created_at_utc=(Get-Date).ToUniversalTime().ToString('o')}
[IO.File]::WriteAllText($CapabilityPath,($Capability|ConvertTo-Json -Depth 10),$Utf8)
$Script = Join-Path $InstallRoot 'companion_action_bridge.py'
$StateRoot = "$env:USERPROFILE\.agentic-pipeline\action-bridge"
$Arguments = "`"$Script`" scan --inbox `"$env:USERPROFILE\Downloads`" --registry `"$RegistryPath`" --state-root `"$StateRoot`""
$Action = New-ScheduledTaskAction -Execute $Python.Source -Argument $Arguments
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'AgenticPipelineCompanionActionBridge' -Action $Action -Trigger $Trigger -Settings $Settings -Description 'Imports validated Companion 1.2.9 JSON Action Packets from Downloads into registered Agentic Pipeline projects.' -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $InstallRoot 'INSTALLATION_RECEIPT.json'),([ordered]@{schema_version='1.0.0';ecosystem_version='1.2.9';status='PASS';project_id=$ProjectId;project_root=$ResolvedProject;source_commit=[string]$PackageManifest.source_commit;release_asset_sha256=if($AssetSha256){$AssetSha256.ToLowerInvariant()}else{$null};package_manifest_sha256=(Get-FileHash -LiteralPath $PackageManifestPath -Algorithm SHA256).Hash.ToLowerInvariant();installed_code_sha256=(Get-FileHash -LiteralPath $Script -Algorithm SHA256).Hash.ToLowerInvariant();source_code_sha256=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant();scheduled_task='AgenticPipelineCompanionActionBridge';background_executable=$Python.Source;installed_at_utc=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json -Depth 10),$Utf8)
Write-Host 'Companion Action Bridge installed.'
