$ErrorActionPreference = 'Stop'
$Root = (Get-Location).Path
$LogPath = Join-Path $Root '.agy/verification/vitest_run.log'
$Watchdog = Join-Path $Root 'scripts/Invoke-TestWithTimeout.ps1'

Write-Host "Running Vitest test suite with 180s watchdog ceiling..."
& pwsh -NoProfile -ExecutionPolicy Bypass -File $Watchdog -Command "npx vitest run --testTimeout=5000 --hookTimeout=5000 --bail=5" -TimeoutSeconds 180 -OutputFile $LogPath
$code = $LASTEXITCODE

if ($code -ne 0) {
  Write-Host "Vitest run finished with failure/timeout code $code (log: $LogPath)" -ForegroundColor Red
  exit $code
}

Write-Host "Vitest run successfully captured to $LogPath" -ForegroundColor Green
