[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$PipelineRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$OutFile = "",
  [switch]$WriteToProject
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-JsonFile {
  param([string]$Path)
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $Text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  return ($Text | ConvertFrom-Json)
}

function Invoke-NativeCapture {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string[]]$ArgumentList
  )
  $OldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $Output = @(& $FilePath @ArgumentList 2>&1)
    $Code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $OldPreference
  }
  return [pscustomobject]@{
    Code = [int]$Code
    Lines = [object[]]$Output
    Text = ([object[]]$Output -join "`n")
  }
}

function Get-RootCommand {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $Match = [regex]::Match($Value.Trim(), '^/[^\s]+')
  if ($Match.Success) { return $Match.Value }
  return $null
}

$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$StateRoot = Join-Path $Project ".agy"
$ArtifactRoot = Join-Path $Project ".artifacts"
$WorkflowRoot = Join-Path $Project ".agents\workflows"

if (!(Test-Path -LiteralPath $Project -PathType Container)) {
  throw "Project root not found: $ProjectRoot"
}

$GitRoot = $null
$GitState = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
  $GitRootResult = Invoke-NativeCapture -FilePath "git" -ArgumentList @("-C", $Project, "rev-parse", "--show-toplevel")
  if ($GitRootResult.Code -eq 0) { $GitRoot = $GitRootResult.Text.Trim() }
  if ($GitRoot) {
    $StatusResult = Invoke-NativeCapture -FilePath "git" -ArgumentList @("-C", $Project, "status", "--porcelain=v1", "--untracked-files=all")
    if ($StatusResult.Code -eq 0) {
      $GitState = if ($StatusResult.Lines.Count -eq 0) { "clean" } else { "dirty" }
    }
  }
}

$PackageVersion = $null
$RuntimeVersion = $null
$PipelineVersionPath = Join-Path $PipelineRoot "VERSION.json"
$PipelineVersion = Read-JsonFile -Path $PipelineVersionPath
if ($PipelineVersion) {
  $PackageVersion = $PipelineVersion.package_version
  $RuntimeVersion = $PipelineVersion.runtime_version
}

$InventoryPath = Join-Path $Project ".agents\COMMAND_INVENTORY.json"
if (!(Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
  $Candidate = Join-Path $PipelineRoot "config\command-inventory.json"
  if (Test-Path -LiteralPath $Candidate -PathType Leaf) { $InventoryPath = $Candidate }
}

$Available = New-Object System.Collections.Generic.List[string]
$InventoryHash = $null
if (Test-Path -LiteralPath $InventoryPath -PathType Leaf) {
  $Inventory = Read-JsonFile -Path $InventoryPath
  foreach ($Item in @($Inventory.commands)) {
    if ($Item.command) { [void]$Available.Add([string]$Item.command) }
  }
  $InventoryHash = (Get-FileHash -LiteralPath $InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
elseif (Test-Path -LiteralPath $WorkflowRoot -PathType Container) {
  foreach ($File in Get-ChildItem -LiteralPath $WorkflowRoot -File -Filter "*.md" | Sort-Object Name) {
    [void]$Available.Add("/" + [System.IO.Path]::GetFileNameWithoutExtension($File.Name))
  }
}

$PhasePath = Join-Path $StateRoot "PHASE_STATUS.json"
$Phase = Read-JsonFile -Path $PhasePath
$CurrentPhase = $null
$CurrentStatus = $null
$NextRequired = $null
$AllowedNow = @()
if ($Phase) {
  $CurrentPhase = $Phase.current_phase
  if ($Phase.status) { $CurrentStatus = $Phase.status }
  elseif ($Phase.project_status) { $CurrentStatus = $Phase.project_status }
  $NextRequired = $Phase.next_required_command
  $AllowedNow = @($Phase.commands_allowed_now)
}

$RoutingErrors = New-Object System.Collections.Generic.List[string]
$AvailableArray = [string[]]($Available.ToArray() | Sort-Object -Unique)
$NextRoot = Get-RootCommand -Value $NextRequired
if ($NextRoot -and ($AvailableArray -notcontains $NextRoot)) {
  [void]$RoutingErrors.Add("next_required_command is not present in available_commands: $NextRoot")
}
foreach ($Command in $AllowedNow) {
  if ($Command -and ($AvailableArray -notcontains [string]$Command)) {
    [void]$RoutingErrors.Add("commands_allowed_now contains an unknown command: $Command")
  }
}

if ($WriteToProject) {
  $OutFile = Join-Path $StateRoot "RUNTIME_HANDSHAKE.json"
}
elseif ([string]::IsNullOrWhiteSpace($OutFile)) {
  $OutFile = Join-Path $env:TEMP ("runtime_handshake_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json")
}

$Handshake = [ordered]@{
  schema_version = "1.0.0"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  pipeline_package_version = $PackageVersion
  runtime_version = $RuntimeVersion
  project_root = $Project
  workspace_root = $Project
  git_root = $GitRoot
  state_root = $StateRoot
  artifact_root = $ArtifactRoot
  command_inventory_path = if (Test-Path -LiteralPath $InventoryPath -PathType Leaf) { $InventoryPath } else { $null }
  command_inventory_sha256 = $InventoryHash
  available_commands = $AvailableArray
  current_phase = $CurrentPhase
  current_status = $CurrentStatus
  next_required_command = $NextRequired
  commands_allowed_now = [string[]]$AllowedNow
  routing_valid = ($RoutingErrors.Count -eq 0)
  routing_errors = [string[]]$RoutingErrors.ToArray()
  git_state = $GitState
}

$Parent = Split-Path -Parent $OutFile
if ($Parent) { New-Item -ItemType Directory -Force $Parent | Out-Null }
[System.IO.File]::WriteAllText($OutFile, ($Handshake | ConvertTo-Json -Depth 20), $Utf8NoBom)

Write-Host "Runtime handshake written: $OutFile"
Write-Host "Available commands: $($AvailableArray.Count)"
Write-Host "Current phase: $CurrentPhase"
Write-Host "Next required command: $NextRequired"
Write-Host "Routing valid: $($Handshake.routing_valid)"
if ($RoutingErrors.Count -gt 0) {
  $RoutingErrors.ToArray() | ForEach-Object { Write-Host "- $_" }
  exit 1
}
exit 0
