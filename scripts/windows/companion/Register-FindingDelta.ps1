[CmdletBinding()]
param(
  [string]$ProjectRoot = ".",
  [Parameter(Mandatory=$true)][string]$FindingInputPath,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy = Join-Path $Root ".agy"
$WorkItem = Get-Content -LiteralPath (Join-Path $Agy "WORK_ITEM.json") -Raw | ConvertFrom-Json
$Head = (@(& git -C $Root rev-parse HEAD 2>&1) -join "`n").Trim()
if ($LASTEXITCODE -ne 0) { throw "Cannot resolve Git HEAD." }
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$FindingDocuments = @(Get-Content -LiteralPath (Resolve-Path -LiteralPath $FindingInputPath).Path -Raw | ConvertFrom-Json)
$SetPath = Join-Path $Agy "FINDINGS.json"
$DeltaPath = Join-Path $Agy "FINDING_DELTA.json"
$Existing = @()
if (Test-Path -LiteralPath $SetPath -PathType Leaf) {
  $Existing = @((Get-Content -LiteralPath $SetPath -Raw | ConvertFrom-Json).findings)
}

$MatrixPath = Join-Path $Agy "AUDIT_COVERAGE_MATRIX.json"
$InitialComplete = $false
$CoverageIds = @()
if (Test-Path -LiteralPath $MatrixPath -PathType Leaf) {
  $Matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
  $InitialComplete = ($Matrix.audit_cycle -eq "initial_comprehensive" -and $Matrix.status -eq "complete")
  $CoverageIds = @($Matrix.acceptance_coverage.coverage_id)
}

$FindingMap = @{}
foreach ($Finding in $Existing) { $FindingMap[[string]$Finding.finding_id] = $Finding }
$Added = @()
$Changed = @()

foreach ($Finding in $FindingDocuments) {
  if ([string]::IsNullOrWhiteSpace([string]$Finding.finding_id)) { throw "finding_id is required." }
  if ($InitialComplete -and $Finding.materiality -eq "product_blocker" -and (-not $Finding.coverage_id -or $CoverageIds -notcontains $Finding.coverage_id)) {
    $Finding.origin = "audit_coverage_miss"
  }
  elseif (-not $Finding.origin) {
    $Finding | Add-Member -NotePropertyName origin -NotePropertyValue "initial_audit"
  }

  $FindingId = [string]$Finding.finding_id
  if ($FindingMap.ContainsKey($FindingId)) { $Changed += $FindingId } else { $Added += $FindingId }
  $FindingMap[$FindingId] = $Finding
}

$All = @($FindingMap.Values | Sort-Object finding_id)
$Now = (Get-Date).ToUniversalTime().ToString("o")
$Set = [ordered]@{
  schema_version = "1.0.0"
  work_item_id = [string]$WorkItem.work_item_id
  target_head = $Head
  findings = $All
  updated_at_utc = $Now
}
$Delta = [ordered]@{
  schema_version = "1.0.0"
  work_item_id = [string]$WorkItem.work_item_id
  target_head = $Head
  added_finding_ids = $Added
  changed_finding_ids = $Changed
  generated_at_utc = $Now
}

if ($Apply) {
  [IO.File]::WriteAllText($SetPath, ($Set | ConvertTo-Json -Depth 30), $Utf8NoBom)
  [IO.File]::WriteAllText($DeltaPath, ($Delta | ConvertTo-Json -Depth 20), $Utf8NoBom)
  Write-Host "Finding delta published."
}
else {
  $Delta | ConvertTo-Json -Depth 20
}
