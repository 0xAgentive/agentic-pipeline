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
. (Join-Path $PSScriptRoot '..\common\NativeProcess.ps1')
function Get-OptionalProperty([object]$Object,[string]$Name,[object]$Default=$null){$Property=$Object.PSObject.Properties[$Name];if($null-eq$Property){return $Default};return $Property.Value}
function Set-OptionalProperty([object]$Object,[string]$Name,[object]$Value){$Property=$Object.PSObject.Properties[$Name];if($null-eq$Property){$Object|Add-Member -NotePropertyName $Name -NotePropertyValue $Value}else{$Property.Value=$Value}}
$WorkItem = Get-Content -LiteralPath (Join-Path $Agy 'WORK_ITEM.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$HeadResult=Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Root,'rev-parse','HEAD')
Assert-AgenticNativeSuccess -Result $HeadResult -Description 'git rev-parse'
$Head=$HeadResult.StdOut.Trim()
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
  $CoverageId=Get-OptionalProperty -Object $Finding -Name 'coverage_id'
  $Origin=Get-OptionalProperty -Object $Finding -Name 'origin'
  if ($InitialComplete -and $Finding.materiality -eq 'product_blocker' -and ([string]::IsNullOrWhiteSpace([string]$CoverageId) -or $CoverageIds -notcontains $CoverageId)) {
    Set-OptionalProperty -Object $Finding -Name 'origin' -Value 'audit_coverage_miss'
  } elseif ([string]::IsNullOrWhiteSpace([string]$Origin)) {
    Set-OptionalProperty -Object $Finding -Name 'origin' -Value 'initial_audit'
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
