<#
.SYNOPSIS
  Invoke-TestWithTimeout.ps1 - Universal Process Watchdog for Agent Test Suites
.DESCRIPTION
  Executes any test command with a strict hard execution ceiling (default 180s).
  If the execution hangs or exceeds the timeout, it forcefully terminates the entire
  process tree (preventing agent lockup/20-minute hangs), writes diagnostics, and exits with code 124.
#>
param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$Command,
  [int]$TimeoutSeconds = 180,
  [string]$OutputFile = ""
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Write-Host "[Test Watchdog] Executing: $Command" -ForegroundColor Cyan
Write-Host "[Test Watchdog] Hard execution ceiling: ${TimeoutSeconds}s" -ForegroundColor Cyan

$processInfo = New-Object System.Diagnostics.ProcessStartInfo
$processInfo.FileName = "pwsh.exe"
$processInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$Command`""
$processInfo.RedirectStandardOutput = $true
$processInfo.RedirectStandardError = $true
$processInfo.UseShellExecute = $false
$processInfo.CreateNoWindow = $true

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $processInfo

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
[void]$process.Start()

$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()

$finished = $process.WaitForExit($TimeoutSeconds * 1000)
$stopwatch.Stop()

if (-not $finished) {
  Write-Host "`n[HARD TIMEOUT ERROR] Test execution exceeded ${TimeoutSeconds}s ceiling!" -ForegroundColor Red
  Write-Host "[HARD TIMEOUT ERROR] Forcefully terminating process tree to prevent agent hang..." -ForegroundColor Red
  
  try {
    & taskkill /F /T /PID $process.Id *> $null
  } catch {}
  
  $timeoutMsg = "`n[HARD TIMEOUT ERROR] Execution exceeded ${TimeoutSeconds} seconds. Process tree killed."
  if ($OutputFile) {
    $parentDir = [System.IO.Path]::GetDirectoryName($OutputFile)
    if ($parentDir -and -not (Test-Path $parentDir)) {
      [System.IO.Directory]::CreateDirectory($parentDir) | Out-Null
    }
    [System.IO.File]::WriteAllText($OutputFile, $timeoutMsg, [System.Text.UTF8Encoding]::new($false))
  }
  
  Write-Host $timeoutMsg -ForegroundColor Red
  exit 124
}

[System.Threading.Tasks.Task]::WaitAll($stdoutTask, $stderrTask)

$stdout = $stdoutTask.Result
$stderr = $stderrTask.Result
$output = $stdout + "`n" + $stderr

if ($OutputFile) {
  $parentDir = [System.IO.Path]::GetDirectoryName($OutputFile)
  if ($parentDir -and -not (Test-Path $parentDir)) {
    [System.IO.Directory]::CreateDirectory($parentDir) | Out-Null
  }
  [System.IO.File]::WriteAllText($OutputFile, $output, [System.Text.UTF8Encoding]::new($false))
}

Write-Host $output
$elapsedSec = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
if ($process.ExitCode -eq 0) {
  Write-Host "[Test Watchdog] Completed successfully in ${elapsedSec}s (Exit Code 0)" -ForegroundColor Green
} else {
  Write-Host "[Test Watchdog] Exited in ${elapsedSec}s with Failure Code $($process.ExitCode)" -ForegroundColor Yellow
}

exit $process.ExitCode
