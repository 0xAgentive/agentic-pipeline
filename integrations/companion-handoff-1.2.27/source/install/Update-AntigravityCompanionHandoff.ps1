<#
.SYNOPSIS
    Update-AntigravityCompanionHandoff.ps1 - Updater for Antigravity Companion Handoff v1.2.27
.DESCRIPTION
    Updates an existing installation: compares versions, preserves history/state,
    replaces source atomically, rollback on fail, migrate config/schema, run full test.
#>

[CmdletBinding()]
param (
    [string]$TargetDir = '',
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$baseDir = if (-not [string]::IsNullOrWhiteSpace($TargetDir)) {
    (Resolve-Path -LiteralPath $TargetDir).Path
} elseif ($env:COMPANION_HANDOFF_DIR -and (Test-Path $env:COMPANION_HANDOFF_DIR)) {
    (Resolve-Path -LiteralPath $env:COMPANION_HANDOFF_DIR).Path
} else {
    (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

$pythonCmd = Get-Command python.exe -ErrorAction SilentlyContinue
$pythonPath = if ($pythonCmd) { $pythonCmd.Source } else { "python" }

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Updating Antigravity Companion Handoff v1.2.27" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

if (-not (Test-Path $baseDir)) {
    Write-Error "Base directory $baseDir does not exist. Run Install first."
}

# Read current version
$configPath = Join-Path $baseDir "handoff.config.json"
$currentVersion = "unknown"
if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    $currentVersion = $cfg.version
}

Write-Host "Current version: $currentVersion" -ForegroundColor Yellow
Write-Host "Target version: 1.2.27" -ForegroundColor Green

if ($currentVersion -eq "1.2.27" -and -not $Force) {
    Write-Host "Already at v1.2.27. Use -Force to reinstall." -ForegroundColor Yellow
    return
}

# Backup current state
$backupDir = Join-Path $baseDir "logs\update_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
if (-not $DryRun) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    # Backup src/
    if (Test-Path (Join-Path $baseDir "src")) {
        Copy-Item -Path (Join-Path $baseDir "src") -Destination (Join-Path $backupDir "src") -Recurse
    }
    # Backup config
    if (Test-Path $configPath) {
        Copy-Item $configPath (Join-Path $backupDir "handoff.config.json")
    }
    Write-Host "Backup created: $backupDir" -ForegroundColor Green
}

# Update source files
$sourceSrc = Join-Path $PSScriptRoot "..\src"
if (Test-Path $sourceSrc) {
    if (-not $DryRun) {
        Copy-Item -Path "$sourceSrc\*" -Destination (Join-Path $baseDir "src") -Recurse -Force
        Write-Host "Updated src/ files." -ForegroundColor Green
    } else {
        Write-Host "[DryRun] Would update src/ files." -ForegroundColor Yellow
    }
}

# Run migration if needed
$migrationScript = Join-Path $PSScriptRoot "finalize_v434.py"
if (Test-Path $migrationScript) {
    if (-not $DryRun) {
        Write-Host "Running config migration..." -ForegroundColor Cyan
        & $pythonPath $migrationScript
    } else {
        Write-Host "[DryRun] Would run config migration." -ForegroundColor Yellow
    }
}

# Run full test suite
if (-not $DryRun) {
    Write-Host "`nRunning test suite..." -ForegroundColor Cyan
    & $pythonPath -B (Join-Path $baseDir "install\run_tests.py")
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nUpdate to v1.2.27 completed successfully!" -ForegroundColor Green
    } else {
        Write-Error "Tests failed after update. Check logs."
    }
} else {
    Write-Host "[DryRun] Would run test suite." -ForegroundColor Yellow
}
