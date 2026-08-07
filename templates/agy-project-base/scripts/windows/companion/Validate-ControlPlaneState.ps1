[CmdletBinding()]
param([string]$ProjectRoot='.',[switch]$RequireActiveLease,[switch]$RequireCompleteAudit)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy=Join-Path $Root '.agy'
$Errors=New-Object System.Collections.Generic.List[string]
foreach($Name in @('PROGRESS_POLICY.json','PROGRESS_STATE.json','NEXT_ACTION.json')){if(!(Test-Path -LiteralPath (Join-Path $Agy $Name) -PathType Leaf)){$Errors.Add("MISSING:$Name")}}
$WorkItemPath=Join-Path $Agy 'WORK_ITEM.json'
$HasWorkItem=Test-Path -LiteralPath $WorkItemPath -PathType Leaf
if(-not $HasWorkItem){
  if($RequireActiveLease-or$RequireCompleteAudit){$Errors.Add('ACTIVE_WORK_ITEM_REQUIRED')}
  if(Test-Path -LiteralPath (Join-Path $Agy 'PROGRESS_STATE.json') -PathType Leaf){$Progress=Get-Content -LiteralPath (Join-Path $Agy 'PROGRESS_STATE.json') -Raw -Encoding UTF8|ConvertFrom-Json;if([string]$Progress.status -notin @('idle','completed')){$Errors.Add('IDLE_PROJECT_PROGRESS_STATE_INVALID')}}
  if(Test-Path -LiteralPath (Join-Path $Agy 'NEXT_ACTION.json') -PathType Leaf){$Next=Get-Content -LiteralPath (Join-Path $Agy 'NEXT_ACTION.json') -Raw -Encoding UTF8|ConvertFrom-Json;if($Next.route -or $Next.auto_continue -eq $true){$Errors.Add('IDLE_PROJECT_NEXT_ACTION_INVALID')}}
}else{
  if(Test-Path -LiteralPath (Join-Path $Agy 'FINDINGS.json') -PathType Leaf){try{& (Join-Path $Root 'scripts\windows\companion\Test-FindingSet.ps1') -ProjectRoot $Root|Out-Null}catch{$Errors.Add('FINDINGS_INVALID')}}
  if($RequireActiveLease){foreach($Name in @('EXECUTION_SCOPE.json','EXECUTION_LEASE.json','STAGE_FIREWALL.json','RUNTIME_HANDSHAKE.json')){if(!(Test-Path -LiteralPath (Join-Path $Agy $Name) -PathType Leaf)){$Errors.Add("MISSING:$Name")}};if($Errors.Count-eq0){try{& (Join-Path $Root 'scripts\windows\companion\Test-ExecutionLease.ps1') -ProjectRoot $Root -BeforeWrite|Out-Null}catch{$Errors.Add('LEASE_INVALID')}}}
  if($RequireCompleteAudit){try{& (Join-Path $Root 'scripts\windows\companion\Test-AuditCoverageMatrix.ps1') -ProjectRoot $Root|Out-Null}catch{$Errors.Add('AUDIT_MATRIX_INVALID')}}
}
if($Errors.Count){Write-Host 'Control-plane validation failed:';$Errors|ForEach-Object{Write-Host "- $_"};exit 1}
Write-Host 'Control-plane validation passed.'
exit 0
