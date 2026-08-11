<#
.SYNOPSIS
    Uninstall-AntigravityCompanionHandoff.ps1 - Uninstaller for Antigravity Companion Handoff v4.3.4
.DESCRIPTION
    Removes hook registration, scheduled task, and optionally archive data.
#>

[CmdletBinding()]
param (
    [switch]$RemoveArchives,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$baseDir = "C:\Scripts\AntigravityProjects\companion-handoff"
$hooksFile = "C:\Users\Администратор\AppData\Roaming\.gemini\config\hooks.json"
if (-not (Test-Path $hooksFile)) {
    $hooksFile = "C:\Users\Администратор\.gemini\config\hooks.json"
}

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Uninstalling Antigravity Companion Handoff v4.3.4" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

# Remove hook
if (Test-Path $hooksFile) {
    if (-not $DryRun) {
        $pythonPath = "C:\Users\Администратор\AppData\Local\Programs\Python\Python314\python.exe"
        if (-not (Test-Path $pythonPath)) { $pythonPath = "python" }

        $pyCode = @"
import os, json
hooks_file = r"$hooksFile"
if os.path.exists(hooks_file):
    with open(hooks_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    if 'companion-handoff-on-stop' in data:
        del data['companion-handoff-on-stop']
        with open(hooks_file, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print('[Uninstaller] Removed companion-handoff-on-stop hook.')
    else:
        print('[Uninstaller] Hook not found, nothing to remove.')
"@
        & $pythonPath -c $pyCode
        Write-Host "Removed companion-handoff-on-stop hook." -ForegroundColor Green
    } else {
        Write-Host "[DryRun] Would remove companion-handoff-on-stop hook." -ForegroundColor Yellow
    }
}

# Remove scheduled task
$taskName = "AntigravityCompanionHandoffWorker"
if (-not $DryRun) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task: $taskName" -ForegroundColor Green
} else {
    Write-Host "[DryRun] Would remove scheduled task: $taskName" -ForegroundColor Yellow
}

# Optionally remove archives
if ($RemoveArchives) {
    $archiveDir = Join-Path $baseDir "handoffs"
    if (Test-Path $archiveDir) {
        if (-not $DryRun) {
            Remove-Item -Path $archiveDir -Recurse -Force
            Write-Host "Removed archive directory: $archiveDir" -ForegroundColor Red
        } else {
            Write-Host "[DryRun] Would remove archive directory: $archiveDir" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "Handoff archives preserved (use -RemoveArchives to delete)." -ForegroundColor Yellow
}

Write-Host "Uninstallation completed." -ForegroundColor Green
