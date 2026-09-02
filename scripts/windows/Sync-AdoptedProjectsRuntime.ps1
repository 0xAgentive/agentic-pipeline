[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$FrameworkRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$TemplateRules = Join-Path $FrameworkRoot 'templates\agy-project-base\.agents\rules'
$WatchdogScript = Join-Path $FrameworkRoot 'scripts\Invoke-WithTimeout.ps1'
$RegPath = "$env:USERPROFILE\.agentic-pipeline\project-registry.json"

if (-not (Test-Path $RegPath)) {
    Write-Host "No project registry found at $RegPath"
    exit 0
}

$reg = Get-Content $RegPath -Raw -Encoding UTF8 | ConvertFrom-Json
$uniqueRoots = $reg.projects | ForEach-Object { $_.project_root } | Select-Object -Unique

Write-Host "=== Synchronizing Pipeline Updates Across All Registered Projects ===" -ForegroundColor Cyan

foreach ($pRoot in $uniqueRoots) {
    if (-not (Test-Path $pRoot)) {
        Write-Host "[SKIP] Path does not exist: $pRoot" -ForegroundColor Yellow
        continue
    }

    Write-Host "
Updating project: $pRoot" -ForegroundColor Green
    
    # 1. Update rules if .agents/rules exists
    $rulesDir = Join-Path $pRoot '.agents\rules'
    if (Test-Path $rulesDir) {
        Get-ChildItem $TemplateRules -File | ForEach-Object {
            $dest = Join-Path $rulesDir $_.Name
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        }
        Write-Host "  -> Updated rules in $rulesDir" -ForegroundColor DarkGreen
    }
    
    # 2. Update Invoke-WithTimeout.ps1 if scripts exists
    $scriptsDir = Join-Path $pRoot 'scripts'
    if (Test-Path $scriptsDir) {
        $destScript = Join-Path $scriptsDir 'Invoke-WithTimeout.ps1'
        Copy-Item -LiteralPath $WatchdogScript -Destination $destScript -Force
        Write-Host "  -> Updated Invoke-WithTimeout.ps1 in $scriptsDir" -ForegroundColor DarkGreen
    }
}

Write-Host "
[DONE] All registered projects synchronized with latest pipeline rules and scripts!" -ForegroundColor Cyan
