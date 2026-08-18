[CmdletBinding()]
param(
  [string]$ProjectRoot = '.',
  [string]$MetricsPath = '',
  [switch]$Json
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy = Join-Path $Root '.agy'
$ResolvedMetricsPath = if (-not [string]::IsNullOrWhiteSpace($MetricsPath)) {
  if ([IO.Path]::IsPathRooted($MetricsPath)) { $MetricsPath } else { Join-Path $Root $MetricsPath }
} else {
  Join-Path $Agy 'RUN_METRICS.ndjson'
}

if (-not (Test-Path -LiteralPath $ResolvedMetricsPath -PathType Leaf)) {
  $EmptySummary = [ordered]@{
    schema_version = '1.0.0'
    total_operations = 0
    p50_duration_ms = 0.0
    p95_duration_ms = 0.0
    error_count = 0
    error_rate = 0.0
    by_operation = @()
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
  }
  if ($Json) {
    $EmptySummary | ConvertTo-Json -Depth 10
  } else {
    Write-Host "No metrics found at: $ResolvedMetricsPath"
  }
  return
}

$Lines = Get-Content -LiteralPath $ResolvedMetricsPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$Records = @($Lines | ForEach-Object { $_ | ConvertFrom-Json })

if ($Records.Count -eq 0) {
  $EmptySummary = [ordered]@{
    schema_version = '1.0.0'
    total_operations = 0
    p50_duration_ms = 0.0
    p95_duration_ms = 0.0
    error_count = 0
    error_rate = 0.0
    by_operation = @()
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
  }
  if ($Json) { $EmptySummary | ConvertTo-Json -Depth 10 } else { Write-Host 'No metric records found.' }
  return
}

$Durations = @($Records | ForEach-Object { [double]$_.duration_ms } | Sort-Object)
function Get-Percentile([double[]]$Sorted, [double]$Percentile) {
  if ($Sorted.Count -eq 0) { return 0.0 }
  $Index = [int][Math]::Floor(($Sorted.Count - 1) * $Percentile)
  return [Math]::Round($Sorted[$Index], 2)
}

$P50 = Get-Percentile $Durations 0.50
$P95 = Get-Percentile $Durations 0.95
$ErrorCount = @($Records | Where-Object { $_.success -eq $false -or [string]$_.status -eq 'failed' }).Count
$ErrorRate = [Math]::Round(($ErrorCount / $Records.Count), 4)

$Grouped = @($Records | Group-Object -Property operation | ForEach-Object {
  $OpDurations = @($_.Group | ForEach-Object { [double]$_.duration_ms } | Sort-Object)
  $OpErrors = @($_.Group | Where-Object { $_.success -eq $false -or [string]$_.status -eq 'failed' }).Count
  [ordered]@{
    operation = $_.Name
    count = $_.Count
    p50_ms = Get-Percentile $OpDurations 0.50
    p95_ms = Get-Percentile $OpDurations 0.95
    errors = $OpErrors
    error_rate = [Math]::Round(($OpErrors / $_.Count), 4)
  }
})

$Summary = [ordered]@{
  schema_version = '1.0.0'
  total_operations = $Records.Count
  p50_duration_ms = $P50
  p95_duration_ms = $P95
  error_count = $ErrorCount
  error_rate = $ErrorRate
  by_operation = $Grouped
  generated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}

if ($Json) {
  $Summary | ConvertTo-Json -Depth 10
} else {
  Write-Host ("=== Operation Metrics Summary ===") -ForegroundColor Cyan
  Write-Host ("Total operations: {0} | p50: {1}ms | p95: {2}ms | Errors: {3} ({4:P2})" -f $Records.Count, $P50, $P95, $ErrorCount, $ErrorRate)
  $Grouped | Format-Table -AutoSize
}
