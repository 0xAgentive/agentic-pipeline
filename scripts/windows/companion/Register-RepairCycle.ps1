[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [Parameter(Mandatory=$true)][string]$PhaseId,
  [Parameter(Mandatory=$true)][string]$Subsystem,
  [ValidateSet("audit","fixcritical","verification","human_decision")][string]$Action,
  [ValidateSet("passed","failed","partial","blocked","continued","accepted_debt","deferred","redesign")][string]$Outcome,
  [string]$Notes = "",
  [switch]$Apply
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$AgyRoot = Join-Path $Project ".agy"
$ContractPath = Join-Path $AgyRoot "PHASE_CONTRACT.json"
$LedgerPath = Join-Path $AgyRoot "REPAIR_LEDGER.ndjson"

if (!(Test-Path -LiteralPath $ContractPath -PathType Leaf)) {
  throw "Frozen phase contract is required before recording a repair cycle: $ContractPath"
}
$ContractText = [System.IO.File]::ReadAllText($ContractPath, [System.Text.Encoding]::UTF8)
$Contract = $ContractText | ConvertFrom-Json
if ($Contract.phase_id -ne $PhaseId) {
  throw "Phase ID does not match the frozen contract. Contract=$($Contract.phase_id) Requested=$PhaseId"
}

$Records = New-Object System.Collections.Generic.List[object]
if (Test-Path -LiteralPath $LedgerPath -PathType Leaf) {
  foreach ($Line in [System.IO.File]::ReadAllLines($LedgerPath, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($Line)) { continue }
    try { [void]$Records.Add(($Line | ConvertFrom-Json)) }
    catch { throw "Invalid NDJSON record in $LedgerPath" }
  }
}

$PhaseRepairs = @($Records.ToArray() | Where-Object {
  $_.phase_id -eq $PhaseId -and $_.action -eq "fixcritical"
}).Count
$SubsystemCycles = @($Records.ToArray() | Where-Object {
  $_.phase_id -eq $PhaseId -and $_.subsystem -eq $Subsystem -and $_.action -eq "fixcritical"
}).Count

$MaxTotal = [int]$Contract.repair_budget.max_total_repairs_per_phase
$MaxSubsystem = [int]$Contract.repair_budget.max_audit_fix_cycles_per_subsystem
$WillExceed = $false
if ($Action -eq "fixcritical") {
  if (($PhaseRepairs + 1) -gt $MaxTotal) { $WillExceed = $true }
  if (($SubsystemCycles + 1) -gt $MaxSubsystem) { $WillExceed = $true }
}

Write-Host "Phase repairs used: $PhaseRepairs / $MaxTotal"
Write-Host "Subsystem repairs used: $SubsystemCycles / $MaxSubsystem"
Write-Host "Requested action: $Action"

if ($WillExceed) {
  Write-Host "REPAIR BUDGET EXHAUSTED. Human decision required."
  Write-Host "Allowed decisions: continue repair, accept debt, defer, redesign."
  exit 2
}

$RepairIndex = if ($Action -eq "fixcritical") { $PhaseRepairs + 1 } else { $PhaseRepairs }
$Record = [ordered]@{
  schema_version = "1.0.0"
  recorded_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  phase_id = $PhaseId
  subsystem = $Subsystem
  action = $Action
  outcome = $Outcome
  repair_index = $RepairIndex
  notes = $Notes
}

if (!$Apply) {
  Write-Host "DRY RUN. Record was not appended."
  $Record | ConvertTo-Json -Depth 10
  exit 0
}

New-Item -ItemType Directory -Force $AgyRoot | Out-Null
$LineToWrite = ($Record | ConvertTo-Json -Compress -Depth 10) + "`n"
$Bytes = $Utf8NoBom.GetBytes($LineToWrite)
$Stream = New-Object System.IO.FileStream -ArgumentList @(
  $LedgerPath,
  [System.IO.FileMode]::Append,
  [System.IO.FileAccess]::Write,
  [System.IO.FileShare]::Read
)
try {
  $Stream.Write($Bytes, 0, $Bytes.Length)
  $Stream.Flush()
}
finally {
  $Stream.Dispose()
}

Write-Host "Repair ledger updated: $LedgerPath"
exit 0
