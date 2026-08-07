[CmdletBinding()]
param([string]$ProjectRoot='.',[switch]$Apply)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy=Join-Path $Root '.agy'
$Utf8=[Text.UTF8Encoding]::new($false)
$Now=(Get-Date).ToUniversalTime().ToString('o')
$WorkItemPath=Join-Path $Agy 'WORK_ITEM.json'
$WorkItem=if(Test-Path -LiteralPath $WorkItemPath -PathType Leaf){Get-Content -LiteralPath $WorkItemPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
$WorkItemId=if($WorkItem){[string]$WorkItem.work_item_id}else{$null}
$LegacyNames=@('CONVERGENCE_BUDGET.json','REPAIR_BUDGET.json','repair-ledger.ndjson')
$Legacy=@($LegacyNames|ForEach-Object{Join-Path $Agy $_}|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf})
$FindingsMalformed=$false;$OpenProduct=0;$OpenVerification=0
$FindingsPath=Join-Path $Agy 'FINDINGS.json'
if(Test-Path -LiteralPath $FindingsPath -PathType Leaf){
  try{
    $Payload=Get-Content -LiteralPath $FindingsPath -Raw -Encoding UTF8|ConvertFrom-Json
    $Findings=@($Payload.findings)
    foreach($Finding in $Findings){
      if(-not$Finding.finding_id-or-not$Finding.materiality){$FindingsMalformed=$true;continue}
      $State=[string](if($Finding.lifecycle_status){$Finding.lifecycle_status}else{$Finding.status})
      $Closed=$State-in@('verified_resolved','resolved','deferred','accepted_risk','superseded','false_positive')
      if(-not$Closed-and[string]$Finding.materiality-eq'product_blocker'){$OpenProduct++}
      if(-not$Closed-and[string]$Finding.materiality-in@('verification_blocker','release_blocker')){$OpenVerification++}
    }
  }catch{$FindingsMalformed=$true}
}
$Route=if($FindingsMalformed){'/auditphase'}elseif($OpenProduct-gt0){'/fixcritical'}elseif($OpenVerification-gt0){'/auditphase'}elseif($WorkItem-and[string]$WorkItem.status-in@('active','implementation','repair','audit','ready','in_progress')){if($WorkItem.preferred_command){[string]$WorkItem.preferred_command}else{'/nextphase'}}else{$null}
$Progress=[ordered]@{schema_version='1.1.0';work_item_id=$WorkItemId;status=if($Route){'progressing'}else{'idle'};observations_count=0;consecutive_no_progress=0;same_failure_count=0;last_failure_fingerprint=$null;last_metrics=$null;last_progress_fingerprint=$null;last_material_change='migrated_from_numeric_repair_budget';owner_decision_required=$false;owner_decision_reason=$null;updated_at_utc=$Now;history=@([ordered]@{at_utc=$Now;event='owner_autonomy_migration';legacy_budget_files=@($Legacy|ForEach-Object{[IO.Path]::GetFileName($_)});route=$Route;findings_malformed=$FindingsMalformed})}
$TaskRelative='.agy/inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md'
$Next=[ordered]@{schema_version='1.1.0';work_item_id=$WorkItemId;route=$Route;auto_continue=[bool]$Route;owner_decision_required=$false;owner_decision_reason=$null;technical_task_path=if(Test-Path -LiteralPath (Join-Path $Root $TaskRelative) -PathType Leaf){$TaskRelative}else{$null};updated_at_utc=$Now}
if($WorkItem){
 foreach($Name in @('convergence_policy','repair_budget','repair_batches_used','repair_batch_limit')){$WorkItem.PSObject.Properties.Remove($Name)}
 $WorkItem|Add-Member -NotePropertyName progress_policy -NotePropertyValue ([ordered]@{auto_continue_while_progress=$true;consecutive_no_progress_limit=2;same_failure_limit=2}) -Force
 $WorkItem.updated_at_utc=$Now
}
$HandshakePath=Join-Path $Agy 'RUNTIME_HANDSHAKE.json';$Handshake=$null
if(Test-Path -LiteralPath $HandshakePath -PathType Leaf){
 $Handshake=Get-Content -LiteralPath $HandshakePath -Raw -Encoding UTF8|ConvertFrom-Json
 $Handshake.installed=[ordered]@{package_version='1.2.8';runtime_version='1.2.8';companion_version='1.2.8'}
 $Handshake|Add-Member -NotePropertyName progress_guard -NotePropertyValue ([ordered]@{numeric_repair_budget=$false;auto_continue_while_progress=$true;consecutive_no_progress_limit=2;same_failure_limit=2}) -Force
 if($Handshake.routing){$Handshake.routing.next_required_command=$Route;$Handshake.routing.resolved_commands_allowed_now=if($Route){@($Route)}else{@()};$Handshake.routing.product_execution_allowed=($Route-in@('/nextphase','/fixcritical','/fastpatch'));$Handshake.routing.release_execution_allowed=($Route-eq'/shipcheck')}
 $Handshake.generated_at_utc=$Now
}
$Result=[ordered]@{schema_version='1.1.0';status='PASS';project_root=$Root;work_item_id=$WorkItemId;legacy_budget_files=@($Legacy|ForEach-Object{[IO.Path]::GetFileName($_)});next_route=$Route;numerical_repair_budget_enabled=$false;findings_malformed=$FindingsMalformed;open_product_blockers=$OpenProduct;open_verification_blockers=$OpenVerification;generated_at_utc=$Now}
if(-not$Apply){[ordered]@{progress=$Progress;next_action=$Next;result=$Result}|ConvertTo-Json -Depth 30;exit 0}
$HistoryRoot=Join-Path $Agy ('history\legacy-repair-budget\'+(Get-Date -Format 'yyyyMMdd-HHmmss'));if($Legacy.Count){New-Item -ItemType Directory -Force $HistoryRoot|Out-Null}
foreach($Path in $Legacy){Move-Item -LiteralPath $Path -Destination (Join-Path $HistoryRoot ([IO.Path]::GetFileName($Path))) -Force}
if($WorkItem){[IO.File]::WriteAllText($WorkItemPath,($WorkItem|ConvertTo-Json -Depth 40),$Utf8)}
[IO.File]::WriteAllText((Join-Path $Agy 'PROGRESS_STATE.json'),($Progress|ConvertTo-Json -Depth 30),$Utf8)
[IO.File]::WriteAllText((Join-Path $Agy 'NEXT_ACTION.json'),($Next|ConvertTo-Json -Depth 20),$Utf8)
if($Handshake){[IO.File]::WriteAllText($HandshakePath,($Handshake|ConvertTo-Json -Depth 40),$Utf8)}
[IO.File]::WriteAllText((Join-Path $Agy 'OWNER_AUTONOMY_MIGRATION_RESULT.json'),($Result|ConvertTo-Json -Depth 20),$Utf8)
Write-Host 'Active work item migrated to progress-based continuation. Legacy counter-based routing was removed.'
