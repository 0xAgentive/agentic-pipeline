<#
.SYNOPSIS
    Uninstall-AntigravityCompanionHandoff.ps1 - Uninstaller for Antigravity Companion Handoff v1.2.26
.DESCRIPTION
    Removes hook registration, scheduled task, and optionally archive data.
#>

[CmdletBinding()]
param (
    [string]$TargetDir = '',
    [switch]$RemoveArchives,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$baseDir = if (-not [string]::IsNullOrWhiteSpace($TargetDir)) {
    (Resolve-Path -LiteralPath $TargetDir).Path
} elseif ($env:COMPANION_HANDOFF_DIR -and (Test-Path $env:COMPANION_HANDOFF_DIR)) {
    (Resolve-Path -LiteralPath $env:COMPANION_HANDOFF_DIR).Path
} else {
    (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

$hooksFile = if ($env:APPDATA -and (Test-Path (Join-Path $env:APPDATA '.gemini\config\hooks.json'))) {
    Join-Path $env:APPDATA '.gemini\config\hooks.json'
} elseif ($env:USERPROFILE -and (Test-Path (Join-Path $env:USERPROFILE '.gemini\config\hooks.json'))) {
    Join-Path $env:USERPROFILE '.gemini\config\hooks.json'
} else {
    Join-Path $env:USERPROFILE '.gemini\config\hooks.json'
}

$pythonCmd = Get-Command python.exe -ErrorAction SilentlyContinue
$pythonPath = if ($pythonCmd) { $pythonCmd.Source } else { "python" }

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Uninstalling Antigravity Companion Handoff v1.2.26" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

# Remove hook
if (Test-Path $hooksFile) {
    if (-not $DryRun) {
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
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Removed scheduled task: $taskName" -ForegroundColor Green
} else {
    Write-Host "[DryRun] Would remove scheduled task: $taskName" -ForegroundColor Yellow
}

# Optionally remove archive and state
if ($RemoveArchives -and (Test-Path $baseDir)) {
    if (-not $DryRun) {
        foreach ($sub in @("archives", "state", "queue", "logs")) {
            $p = Join-Path $baseDir $sub
            if (Test-Path $p) {
                Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "Removed directory: $p" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "[DryRun] Would remove archives, state, queue, and logs directories." -ForegroundColor Yellow
    }
}

Write-Host "Uninstallation complete." -ForegroundColor Cyan
