[CmdletBinding()]
param(
  [string]$InstallRoot = "$env:LOCALAPPDATA\AgenticPipeline\ActionBridge",
  [string]$RegistryPath = "$env:USERPROFILE\.agentic-pipeline\project-registry.json",
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$ProjectId = '',
  [string]$LogicalName = '',
  [switch]$Apply
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Python = Get-Command pythonw -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $Python) { $Python = Get-Command python -ErrorAction Stop | Select-Object -First 1 }
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { throw "Project root is missing: $ProjectRoot" }
$ResolvedProject = (Resolve-Path -LiteralPath $ProjectRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $ResolvedProject '.agy') -PathType Container) -or -not (Test-Path -LiteralPath (Join-Path $ResolvedProject '.agents') -PathType Container)) { throw 'Project is not an installed Agentic Pipeline project.' }
$Leaf = Split-Path -Leaf $ResolvedProject
if ([string]::IsNullOrWhiteSpace($LogicalName)) { $LogicalName = $Leaf }
if ([string]::IsNullOrWhiteSpace($ProjectId)) {
  $ProjectId = ($Leaf -replace '[^A-Za-z0-9._-]','-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw 'ProjectId cannot be derived. Supply -ProjectId explicitly.' }
}
$Source = Join-Path $PSScriptRoot 'companion_action_bridge.py'
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Bridge source is missing: $Source" }
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
$Registry = if (Test-Path -LiteralPath $RegistryPath -PathType Leaf) { Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{schema_version='1.2.8';ecosystem_version='1.2.8';projects=@()} }
$Projects = New-Object System.Collections.Generic.List[object]
foreach ($Item in @($Registry.projects)) { if ([string]$Item.project_id -ne $ProjectId) { [void]$Projects.Add($Item) } }
[void]$Projects.Add([ordered]@{project_id=$ProjectId;project_root=$ResolvedProject;logical_name=$LogicalName;capability_token=$CapabilityToken})
$NewRegistry = [ordered]@{schema_version='1.2.8';ecosystem_version='1.2.8';projects=[object[]]$Projects.ToArray()}
$Utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($RegistryPath,($NewRegistry|ConvertTo-Json -Depth 20),$Utf8)
$Capability = [ordered]@{schema_version='1.2.8';ecosystem_version='1.2.8';project_id=$ProjectId;capability_token=$CapabilityToken;purpose='companion_action_packet_import';created_at_utc=(Get-Date).ToUniversalTime().ToString('o')}
[IO.File]::WriteAllText($CapabilityPath,($Capability|ConvertTo-Json -Depth 10),$Utf8)
$Script = Join-Path $InstallRoot 'companion_action_bridge.py'
$StateRoot = "$env:USERPROFILE\.agentic-pipeline\action-bridge"
$Arguments = "`"$Script`" scan --inbox `"$env:USERPROFILE\Downloads`" --registry `"$RegistryPath`" --state-root `"$StateRoot`""
$Action = New-ScheduledTaskAction -Execute $Python.Source -Argument $Arguments
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'AgenticPipelineCompanionActionBridge' -Action $Action -Trigger $Trigger -Settings $Settings -Description 'Imports validated Companion 1.2.8 JSON Action Packets from Downloads into registered Agentic Pipeline projects.' -Force | Out-Null
Write-Host 'Companion Action Bridge installed.'
