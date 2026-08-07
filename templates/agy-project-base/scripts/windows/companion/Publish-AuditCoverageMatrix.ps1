[CmdletBinding()]
param(
  [string]$ProjectRoot = '.',
  [ValidateSet('initial_comprehensive','final')][string]$AuditCycle = 'initial_comprehensive',
  [string]$CoverageInputPath = '',
  [switch]$Complete,
  [switch]$Apply
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy = Join-Path $Root '.agy'
$WorkItemPath = Join-Path $Agy 'WORK_ITEM.json'
$OutputPath = Join-Path $Agy 'AUDIT_COVERAGE_MATRIX.json'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
if (-not (Test-Path -LiteralPath $WorkItemPath -PathType Leaf)) { throw 'WORK_ITEM.json missing.' }
$WorkItem = Get-Content -LiteralPath $WorkItemPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Head = (@(& git -C $Root rev-parse HEAD 2>&1) -join "`n").Trim()
if ($LASTEXITCODE -ne 0) { throw 'Git HEAD unavailable.' }

if ($CoverageInputPath) {
  $CoverageInput = Get-Content -LiteralPath (Resolve-Path -LiteralPath $CoverageInputPath).Path -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($CoverageInput -is [System.Array]) {
    $AcceptanceRows = @($CoverageInput)
    $DimensionRows = @()
  } else {
    $AcceptanceRows = @($CoverageInput.acceptance_coverage)
    $DimensionRows = @($CoverageInput.dimension_coverage)
  }
} else {
  $AcceptanceRows = @()
  for ($Index = 0; $Index -lt @($WorkItem.acceptance).Count; $Index++) {
    $AcceptanceRows += [pscustomobject]@{
      coverage_id = ('AC-{0:D3}' -f ($Index + 1))
      acceptance_index = $Index
      requirement = [string]$WorkItem.acceptance[$Index]
      surfaces = @('executor_discovery_required')
      evidence_required = @('actual_product_evidence')
      checks = @('product_specific_check_required')
      status = 'not_evaluated'
      notes = @()
    }
  }
  $DimensionRows = @()
  if ($WorkItem.audit_dimensions) {
    foreach ($Property in $WorkItem.audit_dimensions.PSObject.Properties) {
      $Counter = 0
      foreach ($Item in @($Property.Value)) {
        $Counter++
        $SafeDimension = ([string]$Property.Name).ToUpperInvariant() -replace '[^A-Z0-9_.-]','_'
        $DimensionRows += [pscustomobject]@{
          coverage_id = ('DM-{0}-{1:D3}' -f $SafeDimension, $Counter)
          dimension = [string]$Property.Name
          item_id = [string]$Item
          surfaces = @('executor_discovery_required')
          evidence_required = @('actual_product_evidence')
          checks = @('dimension_specific_check_required')
          status = 'not_evaluated'
          notes = @()
        }
      }
    }
  }
}

if ($AcceptanceRows.Count -ne @($WorkItem.acceptance).Count) { throw 'Acceptance coverage row count does not match the immutable owner brief.' }
$ExpectedDimensions = @()
if ($WorkItem.audit_dimensions) {
  foreach ($Property in $WorkItem.audit_dimensions.PSObject.Properties) {
    foreach ($Item in @($Property.Value)) { $ExpectedDimensions += ('{0}::{1}' -f $Property.Name, [string]$Item) }
  }
}
$ActualDimensions = @($DimensionRows | ForEach-Object { '{0}::{1}' -f $_.dimension, $_.item_id })
$MissingDimensions = @($ExpectedDimensions | Where-Object { $ActualDimensions -notcontains $_ })
if ($MissingDimensions.Count -gt 0) { throw ('Audit dimensions are missing: ' + ($MissingDimensions -join ', ')) }
$AllIds = @($AcceptanceRows.coverage_id) + @($DimensionRows.coverage_id)
if (@($AllIds | Select-Object -Unique).Count -ne $AllIds.Count) { throw 'Duplicate coverage IDs.' }
$UncoveredAcceptance = @($AcceptanceRows | Where-Object { $_.status -eq 'not_evaluated' } | ForEach-Object { [int]$_.acceptance_index })
$UncoveredDimensions = @($DimensionRows | Where-Object { $_.status -eq 'not_evaluated' } | ForEach-Object { [string]$_.coverage_id })
$Status = if ($Complete -and $UncoveredAcceptance.Count -eq 0 -and $UncoveredDimensions.Count -eq 0) { 'complete' } elseif ($Complete) { 'blocked' } else { 'draft' }
$Now = (Get-Date).ToUniversalTime().ToString('o')
$Matrix = [ordered]@{
  schema_version = '1.0.0'
  work_item_id = [string]$WorkItem.work_item_id
  target_head = $Head
  audit_cycle = $AuditCycle
  status = $Status
  acceptance_coverage = $AcceptanceRows
  dimension_coverage = $DimensionRows
  uncovered_acceptance_indexes = $UncoveredAcceptance
  uncovered_dimension_ids = $UncoveredDimensions
  generated_at_utc = $Now
  completed_at_utc = if ($Status -eq 'complete') { $Now } else { $null }
}

if ($Apply) {
  $TempPath = $OutputPath + '.tmp'
  [IO.File]::WriteAllText($TempPath, ($Matrix | ConvertTo-Json -Depth 40), $Utf8NoBom)
  Move-Item -LiteralPath $TempPath -Destination $OutputPath -Force
  & (Join-Path $Root 'scripts\windows\companion\Test-AuditCoverageMatrix.ps1') -ProjectRoot $Root
  if ($LASTEXITCODE -ne 0) { throw 'Published audit matrix failed validation.' }
  Write-Host "Audit coverage matrix published: $OutputPath"
} else {
  $Matrix | ConvertTo-Json -Depth 40
}
if ($Complete -and $Status -ne 'complete') { exit 1 }
