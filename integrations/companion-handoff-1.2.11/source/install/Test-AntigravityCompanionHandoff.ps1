<#
.SYNOPSIS
    Test-AntigravityCompanionHandoff.ps1 - Test runner for Antigravity Companion Handoff v4.3.4
.DESCRIPTION
    Runs the full Python test suite and reports results.
#>

$ErrorActionPreference = "Stop"
$baseDir = "C:\Scripts\AntigravityProjects\companion-handoff"
$pythonPath = "C:\Users\Администратор\AppData\Local\Programs\Python\Python314\python.exe"
if (-not (Test-Path $pythonPath)) {
    $pythonPath = "python"
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Testing Antigravity Companion Handoff v4.3.4" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# Compile check
Write-Host "`nCompile check..." -ForegroundColor Cyan
$compileResult = & $pythonPath -c "import py_compile; import os; src=r'$baseDir\src'; [py_compile.compile(os.path.join(src,f), doraise=True) for f in os.listdir(src) if f.endswith('.py')]; print('OK')" 2>&1
if ($compileResult -match 'OK') {
    Write-Host "Compile: PASS" -ForegroundColor Green
} else {
    Write-Host "Compile: FAIL" -ForegroundColor Red
    Write-Host $compileResult
}

# Full test suite
Write-Host "`nRunning test suite..." -ForegroundColor Cyan
& $pythonPath (Join-Path $baseDir "install\run_tests.py")
$exitCode = $LASTEXITCODE

if ($exitCode -eq 0) {
    Write-Host "`nAll tests passed!" -ForegroundColor Green
} else {
    Write-Host "`nSome tests failed." -ForegroundColor Red
}

exit $exitCode
