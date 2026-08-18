<#
.SYNOPSIS
    Test-AntigravityCompanionHandoff.ps1 - Test runner for Antigravity Companion Handoff v1.2.26
.DESCRIPTION
    Runs the full Python test suite and reports results.
#>

[CmdletBinding()]
param (
    [string]$TargetDir = ''
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

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Testing Antigravity Companion Handoff v1.2.26" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# Compile check
Write-Host "`nCompile check..." -ForegroundColor Cyan
$compileResult = & $pythonPath -B -c "import ast, os; src=r'$baseDir\src'; [ast.parse(open(os.path.join(src,f),encoding='utf-8').read(), filename=f) for f in os.listdir(src) if f.endswith('.py')]; print('OK')" 2>&1
if ($compileResult -match 'OK') {
    Write-Host "Compile: PASS" -ForegroundColor Green
} else {
    Write-Host "Compile: FAIL" -ForegroundColor Red
    Write-Host $compileResult
}

# Full test suite
Write-Host "`nRunning test suite..." -ForegroundColor Cyan
& $pythonPath -B (Join-Path $baseDir "install\run_tests.py")
$exitCode = $LASTEXITCODE

if ($exitCode -eq 0) {
    Write-Host "`nAll tests passed!" -ForegroundColor Green
} else {
    Write-Host "`nSome tests failed." -ForegroundColor Red
}

exit $exitCode
