[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$ProjectName,

  [Parameter(Mandatory = $false)]
  [string]$TargetRoot = '',

  [ValidateSet('New', 'Adopt')]
  [string]$Mode = 'New',

  [string]$Description = 'New autonomous Agentic Pipeline project',

  [ValidateSet('Generic', 'TypeScript', 'Python', 'Fullstack', 'Rust', 'Go')]
  [string]$Stack = 'Generic',

  [string]$EcosystemVersion = '1.2.27',

  [switch]$Apply
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$FrameworkRoot = 'C:\Users\Администратор\Documents\antigravity\agentic-pipeline'
$DefaultProjectsBase = 'C:\Users\Администратор\Documents\antigravity'
$RegistryPath = "$env:USERPROFILE\.agentic-pipeline\project-registry.json"

# Clean project name and slug
$CleanName = $ProjectName.Trim()
$ProjectSlug = ($CleanName -replace '[^A-Za-z0-9_-]+', '-').Trim('-')

if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
  $TargetRoot = Join-Path $DefaultProjectsBase $CleanName
}
$TargetDir = [System.IO.Path]::GetFullPath($TargetRoot)

Write-Host "=== Agentic Pipeline Project Scaffolder (v$EcosystemVersion) ===" -ForegroundColor Cyan
Write-Host "Project Name: $CleanName (Slug: $ProjectSlug)"
Write-Host "Target Path:  $TargetDir"
Write-Host "Mode:         $Mode"
Write-Host "Stack:        $Stack"

if (-not (Test-Path $TargetDir)) {
  if ($Mode -eq 'Adopt') {
    throw "Cannot adopt non-existent directory: $TargetDir"
  }
  New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
}

# 1. Initialize Git if not present
if (-not (Test-Path (Join-Path $TargetDir '.git'))) {
  Write-Host "`nInitializing Git repository..." -ForegroundColor Cyan
  & git -C $TargetDir init | Out-Null
  & git -C $TargetDir checkout -b main 2>$null | Out-Null
}

# 2. Run Initialize-AgenticProject.ps1
Write-Host "`nDeploying Agentic Pipeline runtime baseline ($Mode mode)..." -ForegroundColor Cyan
$InitScript = Join-Path $FrameworkRoot 'scripts\windows\Initialize-AgenticProject.ps1'
& pwsh -NoProfile -ExecutionPolicy Bypass -File $InitScript -TargetRoot $TargetDir -Mode $Mode -ConflictPolicy Keep -Apply -AllowDirty

# 3. Run Update-AgenticProjectRuntime-v1.2.27.ps1 to seal 1.2.27 contracts
Write-Host "`nUpgrading & sealing project runtime to v$EcosystemVersion..." -ForegroundColor Cyan
$UpdateScript = Join-Path $FrameworkRoot 'scripts\windows\Update-AgenticProjectRuntime-v1.2.27.ps1'
& pwsh -NoProfile -ExecutionPolicy Bypass -File $UpdateScript -ProjectRoot $TargetDir -Apply -AllowDirty

# 4. Generate/Update Capability Token and Project Registry
Write-Host "`nRegistering project with Companion Action Bridge..." -ForegroundColor Cyan
$AgyDir = Join-Path $TargetDir '.agy'
$CapPath = Join-Path $AgyDir 'ACTION_BRIDGE_CAPABILITY.json'

$Crypto = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$TokenBytes = [byte[]]::new(32)
$Crypto.GetBytes($TokenBytes)
$CapabilityToken = [Convert]::ToHexString($TokenBytes).ToLowerInvariant()
$Crypto.Dispose()

$CapabilityObject = [ordered]@{
  schema_version = '1.2.9'
  ecosystem_version = $EcosystemVersion
  project_id = $ProjectSlug
  capability_token = $CapabilityToken
  purpose = 'companion_action_packet_import'
  created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText($CapPath, ($CapabilityObject | ConvertTo-Json -Depth 10), $Utf8NoBom)

# Update project-registry.json
$RegistryDir = Split-Path -Parent $RegistryPath
if (-not (Test-Path $RegistryDir)) {
  New-Item -ItemType Directory -Force -Path $RegistryDir | Out-Null
}

$Registry = if (Test-Path $RegistryPath) {
  Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
  [PSCustomObject]@{
    schema_version = '1.2.9'
    ecosystem_version = $EcosystemVersion
    projects = @()
  }
}

# Remove existing registration for this project_id or path if any
$ProjectsList = [System.Collections.Generic.List[object]]::new()
foreach ($p in $Registry.projects) {
  if ($p.project_id -ne $ProjectSlug -and $p.project_root -ne $TargetDir) {
    [void]$ProjectsList.Add($p)
  }
}

# Add fresh entry
$ProjectsList.Add([PSCustomObject]@{
  project_id = $ProjectSlug
  project_root = $TargetDir
  logical_name = $CleanName
  ecosystem_version = $EcosystemVersion
  capability_token = $CapabilityToken
})

$Registry.projects = $ProjectsList.ToArray()
$Registry.ecosystem_version = $EcosystemVersion
[IO.File]::WriteAllText($RegistryPath, ($Registry | ConvertTo-Json -Depth 10), $Utf8NoBom)

# 5. Populate Baseline Project Structure if New
if ($Mode -eq 'New') {
  Write-Host "`nScaffolding project directories and templates..." -ForegroundColor Cyan
  
  # Standard subdirectories
  foreach ($sub in @('src', 'tests', 'docs', 'scripts')) {
    $p = Join-Path $TargetDir $sub
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  }

  # README.md
  $ReadmePath = Join-Path $TargetDir 'README.md'
  if (-not (Test-Path $ReadmePath)) {
    $ReadmeText = @"
# $CleanName

$Description

## Overview
This project is developed under the **Agentic Pipeline v$EcosystemVersion** framework with autonomous agent execution, Stage Firewall governance, and Companion Action Bridge integration.

## Architecture
- Root: ``$TargetDir``
- Ecosystem: Agentic Pipeline v$EcosystemVersion
- Stack: $Stack

## Commands
- ``/nextphase`` — Execute approved Companion Action Packet or next work item.
- ``/auditphase`` — Run independent audit and verification gate.
- ``/fixcritical`` — Repair confirmed critical defect.
- ``/fastpatch`` — Apply lightweight focused patch.
- ``/companion-pack`` — Export complete architectural context for ChatGPT / Claude.
"@
    [IO.File]::WriteAllText($ReadmePath, $ReadmeText, $Utf8NoBom)
  }

  # AGENTS.md
  $AgentsMdPath = Join-Path $TargetDir 'AGENTS.md'
  if (-not (Test-Path $AgentsMdPath)) {
    $AgentsText = @"
# Project Instructions: $CleanName

## Purpose
$Description

## Repository Map
- ``src/`` — Primary source code ($Stack).
- ``tests/`` — Unit and integration tests.
- ``scripts/`` — Build, verification, and automation scripts.
- ``docs/`` — Architecture, specs, and decision records.
- ``.agents/`` — Agent workflows, rules, and skills.
- ``.agy/`` — Control Plane authority manifests and state.

## Validation Contract
- Focused tests: run appropriate test suite.
- Full build: verify all modules compile cleanly.
- Code style & types: zero unhandled errors.

## Definition of Done
- Complete test coverage for new functionality.
- Human & machine reports in exact parity.
- 0 unhandled security or logic findings.
"@
    [IO.File]::WriteAllText($AgentsMdPath, $AgentsText, $Utf8NoBom)
  }

  # Initial Git commit
  try {
    & git -C $TargetDir add .agents .agy README.md AGENTS.md 2>$null | Out-Null
    & git -C $TargetDir commit -m "feat(init): bootstrap project with Agentic Pipeline v$EcosystemVersion" 2>$null | Out-Null
  } catch {}
}

# 6. Generate Companion Context Pack
Write-Host "`nGenerating initial Companion Context Pack for ChatGPT..." -ForegroundColor Cyan
$ContextPackScript = 'C:\Users\Администратор\.gemini\config\skills\companion-project-context-pack\scripts\New-CompanionProjectContextPack.ps1'
& pwsh -NoProfile -ExecutionPolicy Bypass -File $ContextPackScript -ProjectRoot $TargetDir -EcosystemVersion $EcosystemVersion | Out-Null

$PackZipPath = Join-Path "$env:USERPROFILE\Documents\antigravity\companion-packs" ("{0}_COMPREHENSIVE_COMPANION_PACK.zip" -f ($ProjectSlug.ToUpperInvariant()))

Write-Host "`n[SUCCESS] Project ready for Agentic Pipeline development!" -ForegroundColor Green
Write-Host "Project Root:    $TargetDir"
Write-Host "Project ID:      $ProjectSlug"
Write-Host "Companion Pack:  $PackZipPath"

return [pscustomobject]@{
  ProjectName = $CleanName
  ProjectId = $ProjectSlug
  ProjectRoot = $TargetDir
  Mode = $Mode
  CompanionPack = $PackZipPath
  CapabilityToken = $CapabilityToken
}
