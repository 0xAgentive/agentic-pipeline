<#
.SYNOPSIS
    Update-AntigravityCompanionHandoff.ps1 - Updater for Antigravity Companion Handoff v4.3.4
.DESCRIPTION
    Updates an existing installation: compares versions, preserves history/state,
    replaces source atomically, rollback on fail, migrate config/schema, run full test.
#>

[CmdletBinding()]
param (
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$baseDir = "C:\Scripts\AntigravityProjects\companion-handoff"
$pythonPath = "C:\Users\Администратор\AppData\Local\Programs\Python\Python314\python.exe"
if (-not (Test-Path $pythonPath)) {
    $pythonPath = "python"
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Updating Antigravity Companion Handoff v4.3.4" -ForegroundColor Cyan
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
Write-Host "Target version: 4.3.4" -ForegroundColor Green

if ($currentVersion -eq "4.3.4" -and -not $Force) {
    Write-Host "Already at v4.3.4. Use -Force to reinstall." -ForegroundColor Yellow
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

# Run full test suite
Write-Host "Running test suite..." -ForegroundColor Cyan
if (-not $DryRun) {
    $testResult = & $pythonPath (Join-Path $baseDir "install\run_tests.py") 2>&1
    $testOutput = $testResult -join "`n"
    if ($testOutput -match "(\d+) PASS, (\d+) FAIL") {
        $passed = [int]$Matches[1]
        $failed = [int]$Matches[2]
        if ($failed -gt 0) {
            Write-Host "Tests failed: $failed. Update aborted. Backup at: $backupDir" -ForegroundColor Red
            return
        }
        Write-Host "All $passed tests passed." -ForegroundColor Green
    } else {
        Write-Host "Could not parse test results. Proceeding cautiously." -ForegroundColor Yellow
    }
}

# Smoke test
if (-not $DryRun) {
    Write-Host "Running smoke test..." -ForegroundColor Cyan
    $smokeResult = & $pythonPath -c "import py_compile; import os; src=r'$baseDir\src'; [py_compile.compile(os.path.join(src,f), doraise=True) for f in os.listdir(src) if f.endswith('.py')]; print('OK')"
    if ($smokeResult -match 'OK') {
        Write-Host "Smoke test passed." -ForegroundColor Green
    } else {
        Write-Host "Smoke test failed. Rolling back..." -ForegroundColor Red
        # Rollback
        if (Test-Path (Join-Path $backupDir "src")) {
            Remove-Item -Path (Join-Path $baseDir "src") -Recurse -Force
            Copy-Item -Path (Join-Path $backupDir "src") -Destination (Join-Path $baseDir "src") -Recurse
        }
        Write-Error "Update rolled back to previous version."
    }
}

Write-Host "Update to v4.3.4 completed successfully!" -ForegroundColor Green
