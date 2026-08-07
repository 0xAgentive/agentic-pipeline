[CmdletBinding()]
param(
  [string]$ProjectRoot = '.',
  [Parameter(Mandatory=$true)][string]$FindingInputPath,
  [switch]$Apply
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy = Join-Path $Root '.agy'
$WorkItem = Get-Content -LiteralPath (Join-Path $Agy 'WORK_ITEM.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Head = (@(& git -C $Root rev-parse HEAD 2>&1) -join "`n").Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve Git HEAD.' }
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$InputPath = (Resolve-Path -LiteralPath $FindingInputPath).Path
$InputRaw = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8
$FindingDocuments = @($InputRaw | ConvertFrom-Json)
$Validator = Join-Path $Root 'scripts\control-plane\validate-findings.cjs'
$Node = (Get-Command node -ErrorAction Stop).Source
$ValidationOutput = $InputRaw | & $Node $Validator
if ($LASTEXITCODE -ne 0) { Write-Host $ValidationOutput; throw 'Finding input is schema-invalid; publication is fail-closed.' }
$SetPath = Join-Path $Agy 'FINDINGS.json'
$DeltaPath = Join-Path $Agy 'FINDING_DELTA.json'
$Existing = @()
if (Test-Path -LiteralPath $SetPath -PathType Leaf) {
  $ExistingRaw = Get-Content -LiteralPath $SetPath -Raw -Encoding UTF8
  $ExistingValidation = $ExistingRaw | & $Node $Validator
  if ($LASTEXITCODE -ne 0) { Write-Host $ExistingValidation; throw 'Existing finding set is invalid; merge is fail-closed.' }
  $Existing = @(($ExistingRaw | ConvertFrom-Json).findings)
}
$MatrixPath = Join-Path $Agy 'AUDIT_COVERAGE_MATRIX.json'
$InitialComplete = $false
$CoverageIds = @()
if (Test-Path -LiteralPath $MatrixPath -PathType Leaf) {
  & (Join-Path $Root 'scripts\windows\companion\Test-AuditCoverageMatrix.ps1') -ProjectRoot $Root
  if ($LASTEXITCODE -ne 0) { throw 'Audit coverage matrix is invalid.' }
  $Matrix = Get-Content -LiteralPath $MatrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $InitialComplete = ($Matrix.audit_cycle -eq 'initial_comprehensive' -and $Matrix.status -eq 'complete')
  $CoverageIds = @($Matrix.acceptance_coverage.coverage_id) + @($Matrix.dimension_coverage.coverage_id)
}
$FindingMap = @{}
foreach ($Finding in $Existing) { $FindingMap[[string]$Finding.finding_id] = $Finding }
$Added = New-Object System.Collections.Generic.List[string]
$Changed = New-Object System.Collections.Generic.List[string]
foreach ($Finding in $FindingDocuments) {
  if ($InitialComplete -and $Finding.materiality -eq 'product_blocker' -and (-not $Finding.coverage_id -or $CoverageIds -notcontains $Finding.coverage_id)) {
    $Finding.origin = 'audit_coverage_miss'
  } elseif (-not $Finding.origin) {
    $Finding | Add-Member -NotePropertyName origin -NotePropertyValue 'initial_audit'
  }
  $FindingId = [string]$Finding.finding_id
  if ($FindingMap.ContainsKey($FindingId)) { $Changed.Add($FindingId) } else { $Added.Add($FindingId) }
  $FindingMap[$FindingId] = $Finding
}
$All = @($FindingMap.Values | Sort-Object finding_id)
$Now = (Get-Date).ToUniversalTime().ToString('o')
$Set = [ordered]@{ schema_version='1.0.0'; work_item_id=[string]$WorkItem.work_item_id; target_head=$Head; findings=$All; updated_at_utc=$Now }
$Delta = [ordered]@{ schema_version='1.0.0'; work_item_id=[string]$WorkItem.work_item_id; target_head=$Head; added_finding_ids=$Added.ToArray(); changed_finding_ids=$Changed.ToArray(); generated_at_utc=$Now }
if ($Apply) {
  $SetJson = $Set | ConvertTo-Json -Depth 40
  $FinalValidation = $SetJson | & $Node $Validator
  if ($LASTEXITCODE -ne 0) { Write-Host $FinalValidation; throw 'Final finding set is invalid; publication is fail-closed.' }
  [IO.File]::WriteAllText($SetPath, $SetJson, $Utf8NoBom)
  [IO.File]::WriteAllText($DeltaPath, ($Delta | ConvertTo-Json -Depth 20), $Utf8NoBom)
  Write-Host 'Finding delta published.'
} else {
  $Delta | ConvertTo-Json -Depth 20
}
