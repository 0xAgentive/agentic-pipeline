[CmdletBinding()]
param(
  [string]$RepoRoot = '.'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptPath = Join-Path $Root 'scripts\windows\companion\Get-OperationMetricsSummary.ps1'
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Metrics summary script not found: $ScriptPath" }

$TempDir = Join-Path $env:TEMP ("agentic-metrics-test-" + [guid]::NewGuid().ToString('N'))
try {
  $Agy = Join-Path $TempDir '.agy'
  New-Item -ItemType Directory -Force -Path $Agy | Out-Null
  $MetricsFile = Join-Path $Agy 'RUN_METRICS.ndjson'

  # Test 1: Empty file / missing file handling
  $EmptyOut = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -ProjectRoot $TempDir -Json | ConvertFrom-Json
  if ($EmptyOut.total_operations -ne 0) { throw 'Empty summary total_operations is not 0' }

  # Test 2: Populate synthetic metrics
  $Records = @(
    [ordered]@{ at_utc = (Get-Date).ToUniversalTime().ToString('o'); operation = 'result_authority_compile'; duration_ms = 45.2; success = $true; status = 'completed' },
    [ordered]@{ at_utc = (Get-Date).ToUniversalTime().ToString('o'); operation = 'result_authority_compile'; duration_ms = 52.1; success = $true; status = 'completed' },
    [ordered]@{ at_utc = (Get-Date).ToUniversalTime().ToString('o'); operation = 'action_packet_import'; duration_ms = 120.5; success = $true; status = 'completed' },
    [ordered]@{ at_utc = (Get-Date).ToUniversalTime().ToString('o'); operation = 'action_packet_import'; duration_ms = 110.0; success = $false; status = 'failed' }
  )
  foreach ($r in $Records) {
    Add-Content -LiteralPath $MetricsFile -Value ($r | ConvertTo-Json -Compress) -Encoding UTF8
  }

  $Summary = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -ProjectRoot $TempDir -Json | ConvertFrom-Json
  if ($Summary.total_operations -ne 4) { throw "Expected 4 operations, got $($Summary.total_operations)" }
  if ($Summary.error_count -ne 1) { throw "Expected 1 error, got $($Summary.error_count)" }
  if ($Summary.error_rate -ne 0.25) { throw "Expected 0.25 error rate, got $($Summary.error_rate)" }
  if ($Summary.by_operation.Count -ne 2) { throw "Expected 2 operation groups, got $($Summary.by_operation.Count)" }

  Write-Host 'OPERATION_METRICS_SUMMARY_TEST=PASS' -ForegroundColor Green
}
finally {
  Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
