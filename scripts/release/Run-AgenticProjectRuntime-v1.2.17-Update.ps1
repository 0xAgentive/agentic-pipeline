[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$RuntimeZip = "",
  [string]$RuntimeSha256 = "",
  [string]$ExpectedSourceCommit = "",
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
    $KitCandidate = Join-Path $PSScriptRoot 'prebuilt\agentic-project-runtime-1.2.17.zip'
    if (Test-Path -LiteralPath $KitCandidate -PathType Leaf) { $RuntimeZip = $KitCandidate }
  }

  $EffectiveRepoRoot = $RepoRoot
  if (![string]::IsNullOrWhiteSpace($RuntimeZip)) {
    if ($ExpectedSourceCommit -notmatch '^[0-9a-fA-F]{40}$') { throw 'ExpectedSourceCommit is required when installing a runtime release ZIP.' }
    if (!(Test-Path -LiteralPath $RuntimeZip -PathType Leaf)) { throw "Runtime overlay ZIP not found: $RuntimeZip" }
    $RuntimeZip = (Resolve-Path -LiteralPath $RuntimeZip).Path
    $ActualRuntimeSha256 = (Get-FileHash -LiteralPath $RuntimeZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($RuntimeSha256) -and $RuntimeSha256.ToLowerInvariant() -ne $ActualRuntimeSha256) { throw 'Runtime ZIP SHA-256 does not match RuntimeSha256.' }
    $RuntimeSha256 = $ActualRuntimeSha256
    $TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-project-runtime-1.2.17-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
    Expand-Archive -LiteralPath $RuntimeZip -DestinationPath $TempRoot -Force
    $VersionFile = Get-ChildItem -LiteralPath $TempRoot -Recurse -File -Filter 'VERSION.json' | Where-Object {
      try {
        $V = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        [string]($V.package_version) -eq '1.2.17' -and [string]($V.runtime_version) -eq '1.2.17'
      } catch { $false }
    } | Select-Object -First 1
    if (!$VersionFile) { throw 'Runtime overlay does not contain the expected VERSION.json.' }
    $EffectiveRepoRoot = Split-Path -Parent $VersionFile.FullName
  }

  $Updater = Join-Path $EffectiveRepoRoot 'scripts\windows\Update-AgenticProjectRuntime-v1.2.17.ps1'
  if (!(Test-Path -LiteralPath $Updater -PathType Leaf)) { throw "Runtime updater not found: $Updater" }

  $UpdaterArguments = @{
    ProjectRoot = $ProjectRoot
    Apply = $Apply
    AllowDirty = $AllowDirty
    SkipValidation = $SkipValidation
  }
  if (-not [string]::IsNullOrWhiteSpace($RuntimeZip)) {
    $UpdaterArguments.RuntimeRoot = $EffectiveRepoRoot
    $UpdaterArguments.RuntimeArchivePath = $RuntimeZip
    $UpdaterArguments.AssetSha256 = $RuntimeSha256
    $UpdaterArguments.ExpectedSourceCommit = $ExpectedSourceCommit
  }
  else {
    $UpdaterArguments.RepoRoot = $EffectiveRepoRoot
  }
  & $Updater @UpdaterArguments

  if ($Apply) {
    Write-Host 'PROJECT RUNTIME 1.2.17 UPDATE COMPLETED.' -ForegroundColor Green
  }
  else {
    Write-Host 'PROJECT RUNTIME 1.2.17 DRY RUN COMPLETED. Re-run with -Apply after review.' -ForegroundColor Yellow
  }
}
finally {
  if ($TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
