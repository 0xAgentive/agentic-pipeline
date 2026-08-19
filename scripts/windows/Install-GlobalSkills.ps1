[CmdletBinding()]
param(
  [string]$TargetSkillsDirectory = "$env:USERPROFILE\.gemini\config\skills",
  [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$SourceSkills = Join-Path $RepoRoot 'skills'

if (-not (Test-Path $SourceSkills)) {
  throw "Source skills directory not found: $SourceSkills"
}

Write-Host "=== Installing Agentic Pipeline Global Skills for Antigravity ===" -ForegroundColor Cyan
Write-Host "Source:      $SourceSkills"
Write-Host "Destination: $TargetSkillsDirectory"

New-Item -ItemType Directory -Force -Path $TargetSkillsDirectory | Out-Null

$Skills = Get-ChildItem -Path $SourceSkills -Directory
$Installed = 0

foreach ($skill in $Skills) {
  $dest = Join-Path $TargetSkillsDirectory $skill.Name
  Write-Host " -> Installing skill: $($skill.Name)" -ForegroundColor Yellow
  Copy-Item -LiteralPath $skill.FullName -Destination $dest -Recurse -Force
  $Installed++
}

Write-Host "`n[SUCCESS] Installed $Installed global Antigravity skills into: $TargetSkillsDirectory" -ForegroundColor Green
Write-Host "You can now use /new-project, /companion-pack, /stitch-sync, and more across all workspaces!"
