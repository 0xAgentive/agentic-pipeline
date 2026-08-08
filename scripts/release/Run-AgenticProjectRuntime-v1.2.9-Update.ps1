[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$RuntimeZip = "",
  [switch]$Apply,
  [switch]$AllowDirty,
  [switch]$SkipValidation
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$TempRoot = $null

try {
  if ([string]::IsNullOrWhiteSpace($RuntimeZip)) {
    $KitCandidate = Join-Path $PSScriptRoot 'prebuilt\agentic-project-runtime-1.2.9.zip'
    if (Test-Path -LiteralPath $KitCandidate -PathType Leaf) { $RuntimeZip = $KitCandidate }
  }

  $EffectiveRepoRoot = $RepoRoot
  if (![string]::IsNullOrWhiteSpace($RuntimeZip)) {
    if (!(Test-Path -LiteralPath $RuntimeZip -PathType Leaf)) { throw "Runtime overlay ZIP not found: $RuntimeZip" }
    $TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-project-runtime-1.2.9-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
    Expand-Archive -LiteralPath $RuntimeZip -DestinationPath $TempRoot -Force
    $VersionFile = Get-ChildItem -LiteralPath $TempRoot -Recurse -File -Filter 'VERSION.json' | Where-Object {
      try {
        $V = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        [string]($V.package_version) -eq '1.2.9' -and [string]($V.runtime_version) -eq '1.2.9'
      } catch { $false }
    } | Select-Object -First 1
    if (!$VersionFile) { throw 'Runtime overlay does not contain the expected VERSION.json.' }
    $EffectiveRepoRoot = Split-Path -Parent $VersionFile.FullName
  }

  $Updater = Join-Path $EffectiveRepoRoot 'scripts\windows\Update-AgenticProjectRuntime-v1.2.9.ps1'
  if (!(Test-Path -LiteralPath $Updater -PathType Leaf)) { throw "Runtime updater not found: $Updater" }

  & $Updater `
    -ProjectRoot $ProjectRoot `
    -RepoRoot $EffectiveRepoRoot `
    -Apply:$Apply `
    -AllowDirty:$AllowDirty `
    -SkipValidation:$SkipValidation

  if ($Apply) {
    Write-Host 'PROJECT RUNTIME 1.2.9 UPDATE COMPLETED.' -ForegroundColor Green
  }
  else {
    Write-Host 'PROJECT RUNTIME 1.2.9 DRY RUN COMPLETED. Re-run with -Apply after review.' -ForegroundColor Yellow
  }
}
finally {
  if ($TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
