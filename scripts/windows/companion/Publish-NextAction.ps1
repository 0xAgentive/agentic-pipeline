[CmdletBinding()]
param(
  [string]$ProjectRoot='.',
  [AllowNull()][AllowEmptyString()][string]$Route=$null,
  [switch]$OwnerDecisionRequired,
  [string]$OwnerDecisionReason='',
  [switch]$Apply
)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy=Join-Path $Root '.agy'
$Wi=Get-Content -LiteralPath (Join-Path $Agy 'WORK_ITEM.json') -Raw -Encoding UTF8|ConvertFrom-Json
$Allowed=@('/nextphase','/fixcritical','/auditphase','/fastpatch','/shipcheck')
$EffectiveRoute=if([string]::IsNullOrWhiteSpace($Route)){$null}else{$Route}
if($EffectiveRoute -and $EffectiveRoute -notin $Allowed){throw "Unsupported route: $EffectiveRoute"}
$TaskRelative='.agy/inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md'
$Next=[ordered]@{
  schema_version='1.1.0'
  work_item_id=[string]$Wi.work_item_id
  route=$EffectiveRoute
  auto_continue=([bool]$EffectiveRoute -and -not [bool]$OwnerDecisionRequired)
  owner_decision_required=[bool]$OwnerDecisionRequired
  owner_decision_reason=if($OwnerDecisionRequired){$OwnerDecisionReason}else{$null}
  technical_task_path=if(Test-Path -LiteralPath (Join-Path $Root $TaskRelative) -PathType Leaf){$TaskRelative}else{$null}
  updated_at_utc=(Get-Date).ToUniversalTime().ToString('o')
}
if($Apply){
  [IO.File]::WriteAllText((Join-Path $Agy 'NEXT_ACTION.json'),($Next|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  if($EffectiveRoute){
    Write-Host "Next action published: $EffectiveRoute"
  }else{
    $WorkItemPath = Join-Path $Agy 'WORK_ITEM.json'
    if (Test-Path -LiteralPath $WorkItemPath -PathType Leaf) {
      try {
        $WiData = Get-Content -LiteralPath $WorkItemPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($WiData.status -ne 'completed') {
          $WiData.status = 'completed'
          $WiData.updated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
          [IO.File]::WriteAllText($WorkItemPath, ($WiData | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        }
      } catch {}
    }
    Write-Host 'Next action closed.'
  }
}else{$Next|ConvertTo-Json -Depth 10}
