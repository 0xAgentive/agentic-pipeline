[CmdletBinding()]
param(
  [string]$ProjectRoot='.',
  [Parameter(Mandatory=$true)][string[]]$FindingIds,
  [Parameter(Mandatory=$true)][string[]]$ScopePaths,
  [Parameter(Mandatory=$true)][string[]]$VerificationRequired,
  [switch]$Apply
)
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy=Join-Path $Root '.agy'
$Wi=Get-Content (Join-Path $Agy 'WORK_ITEM.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$HistoryPath=Join-Path $Agy 'REPAIR_HISTORY.json'
$Ordinal=1
if(Test-Path -LiteralPath $HistoryPath -PathType Leaf){
  $History=Get-Content $HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $Ordinal=[int]$History.repair_iterations_observed+1
}
$Now=(Get-Date).ToUniversalTime().ToString('o')
$Delta=[ordered]@{
  schema_version='2.0.0'
  work_item_id=[string]$Wi.work_item_id
  iteration_id=('RI-{0:D3}' -f $Ordinal)
  repair_budget='disabled'
  finding_ids=@($FindingIds|Select-Object -Unique)
  scope_paths=@($ScopePaths|Select-Object -Unique)
  verification_required=@($VerificationRequired|Select-Object -Unique)
  status='ready'
  generated_at_utc=$Now
  notes=@('The owner brief remains immutable. Repair iteration counts are observational only.')
}
$Out=Join-Path $Agy 'REPAIR_DELTA.json'
if($Apply){
  [IO.File]::WriteAllText($Out,($Delta|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
  Write-Host "Repair delta published: $($Delta.iteration_id). No numerical limit exists."
}else{$Delta|ConvertTo-Json -Depth 20}
