[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [Parameter(Mandatory=$true)][string]$PhaseId,
  [Parameter(Mandatory=$true)][string]$Subsystem,
  [ValidateSet('audit','fixcritical','verification','human_decision')][string]$Action,
  [ValidateSet('passed','failed','partial','blocked','continued','accepted_debt','deferred','redesign')][string]$Outcome,
  [string]$Notes='',
  [switch]$Apply
)
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy=Join-Path $Root '.agy'
$ContractPath=Join-Path $Agy 'PHASE_CONTRACT.json'
if(Test-Path -LiteralPath $ContractPath -PathType Leaf){
  $Contract=Get-Content $ContractPath -Raw -Encoding UTF8|ConvertFrom-Json
  if($Contract.phase_id -and [string]$Contract.phase_id -ne $PhaseId){throw "Phase ID does not match the current contract. Contract=$($Contract.phase_id) Requested=$PhaseId"}
}
$LedgerPath=Join-Path $Agy 'REPAIR_LEDGER.ndjson'
$Existing=0
if(Test-Path -LiteralPath $LedgerPath -PathType Leaf){
  $Existing=@(Get-Content $LedgerPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}
$Record=[ordered]@{
  schema_version='2.0.0'
  recorded_at_utc=(Get-Date).ToUniversalTime().ToString('o')
  phase_id=$PhaseId
  subsystem=$Subsystem
  action=$Action
  outcome=$Outcome
  history_ordinal=$Existing+1
  budget_effect='none'
  notes=$Notes
}
if(-not$Apply){$Record|ConvertTo-Json -Depth 10;exit 0}
New-Item -ItemType Directory -Force $Agy|Out-Null
$Line=($Record|ConvertTo-Json -Compress -Depth 10)+"`n"
[IO.File]::AppendAllText($LedgerPath,$Line,[Text.UTF8Encoding]::new($false))
Write-Host "Repair history updated. Continuation is based on measured progress."
