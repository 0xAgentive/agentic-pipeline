<#
.SYNOPSIS
    Install-AntigravityCompanionHandoff.ps1 - Installer for Antigravity Companion Handoff v4.3.4
.DESCRIPTION
    Configures global Antigravity hooks.json and registers background worker scheduled task.
    Uses wscript.exe + VBS launcher to avoid console window flashing.
#>

[CmdletBinding()]
param (
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$baseDir = "C:\Scripts\AntigravityProjects\companion-handoff"
$hooksFile = "C:\Users\Администратор\AppData\Roaming\.gemini\config\hooks.json"
if (-not (Test-Path $hooksFile)) {
    $hooksFile = "C:\Users\Администратор\.gemini\config\hooks.json"
}
$pythonPath = "C:\Users\Администратор\AppData\Local\Programs\Python\Python314\python.exe"
if (-not (Test-Path $pythonPath)) {
    $pythonPath = "python"
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Installing Antigravity Companion Handoff v4.3.4" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

if (-not (Test-Path $baseDir)) {
    Write-Error "Base directory $baseDir does not exist."
}

# Python script for atomic, non-destructive hooks.json merge
$pyMergeCode = @"
import os, json, time, shutil

hooks_file = r"$hooksFile"
backup_dir = r"$baseDir\logs"
os.makedirs(backup_dir, exist_ok=True)

if os.path.exists(hooks_file):
    ts = time.strftime("%Y%m%d_%H%M%S")
    b_path = os.path.join(backup_dir, f"hooks.json.bak_{ts}")
    shutil.copy2(hooks_file, b_path)
    print(f"[Installer] Created backup: {b_path}")
    with open(hooks_file, "r", encoding="utf-8") as f:
        data = json.load(f)
else:
    data = {}

data["companion-handoff-on-stop"] = {
    "enabled": True,
    "Stop": [
        {
            "type": "command",
            "command": "pythonw C:/Scripts/AntigravityProjects/companion-handoff/src/enqueue_ag_handoff.py",
            "timeout": 15
        }
    ]
}

tmp_hooks = hooks_file + ".tmp"
with open(tmp_hooks, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

json.load(open(tmp_hooks, "r", encoding="utf-8"))
os.replace(tmp_hooks, hooks_file)
print(f"[Installer] Merged companion-handoff-on-stop hook safely.")
"@

if (-not $DryRun) {
    & $pythonPath -c $pyMergeCode
    Write-Host "Registered companion-handoff-on-stop hook safely." -ForegroundColor Green
} else {
    Write-Host "[DryRun] Would add companion-handoff-on-stop hook to $hooksFile" -ForegroundColor Yellow
}

# Register Scheduled Task with wscript.exe + VBS launcher (no console window flash)
$taskName = "AntigravityCompanionHandoffWorker"
$vbsLauncher = Join-Path $baseDir "src\run_worker_hidden.vbs"
$wscriptExe = "C:\Windows\System32\wscript.exe"

if (-not $DryRun) {
    $action = New-ScheduledTaskAction -Execute $wscriptExe -Argument "`"$vbsLauncher`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 0)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Registered Scheduled Task with VBS launcher (hidden, no console): $taskName" -ForegroundColor Green
} else {
    Write-Host "[DryRun] Would register scheduled task: $taskName" -ForegroundColor Yellow
}

# Smoke test: compile all Python modules
if (-not $DryRun) {
    Write-Host "Running smoke test..." -ForegroundColor Cyan
    $smokeResult = & $pythonPath -c "import py_compile; import os; src=r'$baseDir\src'; [py_compile.compile(os.path.join(src,f), doraise=True) for f in os.listdir(src) if f.endswith('.py')]; print('OK')"
    if ($smokeResult -match 'OK') {
        Write-Host "Smoke test passed." -ForegroundColor Green
    } else {
        Write-Error "Smoke test failed: $smokeResult"
    }
}

Write-Host "Installation completed successfully!" -ForegroundColor Green
