[CmdletBinding()]
param([string]$ProjectRoot = '.')
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy = Join-Path $Root '.agy'
$WorkItem = Get-Content -LiteralPath (Join-Path $Agy 'WORK_ITEM.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Matrix = Get-Content -LiteralPath (Join-Path $Agy 'AUDIT_COVERAGE_MATRIX.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Errors = New-Object System.Collections.Generic.List[string]
if ([string]$Matrix.work_item_id -ne [string]$WorkItem.work_item_id) { $Errors.Add('WORK_ITEM_MISMATCH') }
if ($Matrix.audit_cycle -eq 'initial_comprehensive' -and $Matrix.status -ne 'complete') { $Errors.Add('INITIAL_AUDIT_NOT_COMPLETE') }
$Rows = @($Matrix.acceptance_coverage)
for ($Index = 0; $Index -lt @($WorkItem.acceptance).Count; $Index++) {
  if (@($Rows.acceptance_index) -notcontains $Index) { $Errors.Add("ACCEPTANCE_NOT_COVERED:$Index") }
}
$DimensionRows = @($Matrix.dimension_coverage)
if ($WorkItem.audit_dimensions) {
  foreach ($Property in $WorkItem.audit_dimensions.PSObject.Properties) {
    foreach ($Item in @($Property.Value)) {
      $Found = @($DimensionRows | Where-Object { [string]$_.dimension -eq [string]$Property.Name -and [string]$_.item_id -eq [string]$Item })
      if ($Found.Count -ne 1) { $Errors.Add("DIMENSION_NOT_COVERED:$($Property.Name):$Item") }
    }
  }
}
$AllRows = @($Rows) + @($DimensionRows)
$Ids = @($AllRows.coverage_id)
if (@($Ids | Select-Object -Unique).Count -ne $Ids.Count) { $Errors.Add('DUPLICATE_COVERAGE_ID') }
foreach ($Row in $AllRows) {
  if (@($Row.surfaces).Count -eq 0) { $Errors.Add("SURFACES_EMPTY:$($Row.coverage_id)") }
  if (@($Row.evidence_required).Count -eq 0) { $Errors.Add("EVIDENCE_EMPTY:$($Row.coverage_id)") }
  if (@($Row.checks).Count -eq 0) { $Errors.Add("CHECKS_EMPTY:$($Row.coverage_id)") }
  if ($Matrix.status -eq 'complete' -and [string]$Row.status -notin @('covered','finding_open','blocked','not_applicable')) { $Errors.Add("INCOMPLETE_COVERAGE:$($Row.coverage_id)") }
}
if ($Errors.Count -gt 0) {
  $Errors | ForEach-Object { Write-Host "- $_" }
  exit 1
}
Write-Host 'Audit coverage matrix valid.'
exit 0
