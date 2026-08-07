[CmdletBinding()]
param([string]$ProjectRoot='.',[string]$PacketDirectory='',[switch]$Apply)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy=Join-Path $Root '.agy'
$PacketRoot=if([string]::IsNullOrWhiteSpace($PacketDirectory)){Join-Path $Agy 'inbox\ACTIVE_ACTION_PACKET'}else{(Resolve-Path -LiteralPath $PacketDirectory).Path}
$PacketPath=Join-Path $PacketRoot 'ACTION_PACKET.json'
$ReceiptPath=Join-Path $Agy 'ACTION_PACKET_RECEIPT.json'
if(-not(Test-Path -LiteralPath $PacketPath -PathType Leaf)){throw 'No active Action Packet is available.'}
$Node=(Get-Command node -ErrorAction Stop).Source
$Validator=Join-Path $Root 'scripts\control-plane\action-packet.cjs'
& $Node $Validator $PacketRoot | Out-Host
if($LASTEXITCODE -ne 0){throw 'Action Packet validation failed.'}
$Packet=Get-Content -LiteralPath $PacketPath -Raw -Encoding UTF8|ConvertFrom-Json
$Receipt=Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$Receipt.packet_id -ne [string]$Packet.packet_id){throw 'Action Packet receipt identity mismatch.'}
$Capability=Get-Content -LiteralPath (Join-Path $Agy 'ACTION_BRIDGE_CAPABILITY.json') -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$Capability.capability_token -ne [string]$Packet.capability_token){throw 'Action Packet capability mismatch.'}
if([string]$Packet.operation -eq 'new_work_item'){
  if($Apply){& (Join-Path $Root 'scripts\windows\companion\Start-WorkItemTransaction.ps1') -ProjectRoot $Root -ActionPacketPath $PacketPath -Apply;if($LASTEXITCODE -ne 0){throw 'Work-item activation failed.'}}
}else{
  $WorkItemPath=Join-Path $Agy 'WORK_ITEM.json'
  if(-not(Test-Path -LiteralPath $WorkItemPath -PathType Leaf)){throw 'Continuation packet requires an active work item.'}
  $WorkItem=Get-Content -LiteralPath $WorkItemPath -Raw -Encoding UTF8|ConvertFrom-Json
  if([string]$WorkItem.work_item_id -ne [string]$Packet.work_item_id -or [int]$WorkItem.goal_epoch -ne [int]$Packet.goal_epoch){throw 'Continuation packet does not match the active work item.'}
  if([string]$WorkItem.goal -ne [string]$Packet.goal){throw 'Continuation packet attempts to change the immutable owner goal.'}
  if($Apply){& (Join-Path $Root 'scripts\windows\companion\Publish-NextAction.ps1') -ProjectRoot $Root -Route ([string]$Packet.route) -Apply;if($LASTEXITCODE -ne 0){throw 'Next-action activation failed.'}}
}
$Result=[ordered]@{schema_version='1.1.0';status='PASS';packet_id=[string]$Packet.packet_id;operation=[string]$Packet.operation;route=[string]$Packet.route;work_item_id=[string]$Packet.work_item_id;activated_at_utc=(Get-Date).ToUniversalTime().ToString('o')}
if($Apply){$Utf8=[Text.UTF8Encoding]::new($false);[IO.File]::WriteAllText((Join-Path $Agy 'ACTION_PACKET_ACTIVATION_RESULT.json'),($Result|ConvertTo-Json -Depth 10),$Utf8);$Receipt.status='activated';$Receipt.activated_at_utc=$Result.activated_at_utc;[IO.File]::WriteAllText($ReceiptPath,($Receipt|ConvertTo-Json -Depth 20),$Utf8);Write-Host "Action Packet activated: $($Packet.operation) $($Packet.route)"}else{$Result|ConvertTo-Json -Depth 10}
