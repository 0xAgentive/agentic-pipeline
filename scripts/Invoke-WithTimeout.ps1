<#
.SYNOPSIS
  Invoke-WithTimeout.ps1 - Maximum Hardened Process Watchdog for Agent Tasks (Build, Test, Package, Publish)
.DESCRIPTION
  Executes any command with:
  1. Non-interactive environment variables (CI=true, GIT_TERMINAL_PROMPT=0, DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER=1, PIP_NO_INPUT=1).
  2. Closed stdin to prevent interactive keyboard input hangs.
  3. Non-blocking asynchronous task stream draining.
  4. Strict hard execution ceiling (default 180s).
  5. Deterministic process tree termination (taskkill /F /T) on timeout.
#>
param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$Command,
  [int]$TimeoutSeconds = 180,
  [string]$OutputFile = ""
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Write-Host "[Process Watchdog] Executing: $Command" -ForegroundColor Cyan
Write-Host "[Process Watchdog] Hard execution ceiling: ${TimeoutSeconds}s | Stdin closed | Non-interactive mode enforced" -ForegroundColor Cyan

$processInfo = New-Object System.Diagnostics.ProcessStartInfo
$processInfo.FileName = "pwsh.exe"
$processInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$Command`""
$processInfo.RedirectStandardOutput = $true
$processInfo.RedirectStandardError = $true
$processInfo.RedirectStandardInput = $true
$processInfo.UseShellExecute = $false
$processInfo.CreateNoWindow = $true

# Enforce non-interactive environment across all runtimes
$processInfo.Environment["CI"] = "true"
$processInfo.Environment["DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER"] = "1"
$processInfo.Environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
$processInfo.Environment["GIT_TERMINAL_PROMPT"] = "0"
$processInfo.Environment["NPM_CONFIG_YES"] = "true"
$processInfo.Environment["PIP_NO_INPUT"] = "1"
$processInfo.Environment["PYTHONUNBUFFERED"] = "1"

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $processInfo

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
[void]$process.Start()

# Close standard input immediately so no child process blocks waiting for input
try {
  $process.StandardInput.Close()
} catch {}

$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()

$finished = $process.WaitForExit($TimeoutSeconds * 1000)
$stopwatch.Stop()

if (-not $finished) {
  Write-Host "`n[HARD TIMEOUT ERROR] Execution exceeded ${TimeoutSeconds}s ceiling!" -ForegroundColor Red
  Write-Host "[HARD TIMEOUT ERROR] Terminating entire process tree (PID: $($process.Id)) to protect agent continuity..." -ForegroundColor Red
  
  try {
    & taskkill /F /T /PID $process.Id *> $null
  } catch {}
  
  $timeoutMsg = "`n[HARD TIMEOUT ERROR] Execution exceeded ${TimeoutSeconds} seconds. Process tree was forcefully killed."
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
  Write-Host "[Process Watchdog] Completed successfully in ${elapsedSec}s (Exit Code 0)" -ForegroundColor Green
} else {
  Write-Host "[Process Watchdog] Exited in ${elapsedSec}s with Failure Code $($process.ExitCode)" -ForegroundColor Yellow
}

exit $process.ExitCode
