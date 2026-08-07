[CmdletBinding()]
param([string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Node = (Get-Command node -ErrorAction Stop).Source
$Hook = Join-Path $ProjectRoot '.agents\hooks\agentic_runtime_hook.cjs'
$HooksJson = Join-Path $ProjectRoot '.agents\hooks.json'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) { throw 'Active Node hook is missing.' }
if (-not (Test-Path -LiteralPath $HooksJson -PathType Leaf)) { throw 'hooks.json is missing.' }
$Config = Get-Content -LiteralPath $HooksJson -Raw -Encoding UTF8 | ConvertFrom-Json
$Group = $Config.'agentic-owner-autonomy'
if (-not $Group -or $Group.enabled -ne $true) { throw 'Owner-autonomy hook registration is missing or disabled.' }
foreach ($EventName in @('PreToolUse','PostToolUse','PreInvocation','Stop')) {
  if (-not $Group.PSObject.Properties[$EventName] -or @($Group.$EventName).Count -eq 0) { throw "Hook event missing: $EventName" }
}
$TempRoot = Join-Path $env:TEMP ('agentic-hook-contract-' + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Force (Join-Path $TempRoot '.agy') | Out-Null
  New-Item -ItemType Directory -Force (Join-Path $TempRoot '.agents') | Out-Null
  New-Item -ItemType Directory -Force (Join-Path $TempRoot 'src') | Out-Null
  [IO.File]::WriteAllText((Join-Path $TempRoot 'src\base.ts'),'export const base = true;',[Text.UTF8Encoding]::new($false))
  & git -C $TempRoot init -b main | Out-Null
  & git -C $TempRoot -c user.name='Hook Contract' -c user.email='hook@local.invalid' add --all
  & git -C $TempRoot -c user.name='Hook Contract' -c user.email='hook@local.invalid' -c commit.gpgsign=false commit -m baseline | Out-Null
  $Head = (& git -C $TempRoot rev-parse HEAD).Trim()
  $Now = (Get-Date).ToUniversalTime().ToString('o')
  function Get-TextSha([string]$Text){$Bytes=[Text.Encoding]::UTF8.GetBytes($Text);$Hash=[Security.Cryptography.SHA256]::Create();try{return([Convert]::ToHexString($Hash.ComputeHash($Bytes))).ToLowerInvariant()}finally{$Hash.Dispose()}}
  function Get-FileSha([string]$Path){return(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
  $WorkItem = [ordered]@{schema_version='1.0.0';work_item_id='hook-test';goal_epoch=1;goal='Hook test';assurance_mode='guarded';status='active';owner_approved=$true;owner_interaction_policy='hard_stop_only';scope_binding='exact';created_at_utc=$Now;updated_at_utc=$Now;stage_profile='general'}
  $Scope = [ordered]@{schema_version='1.0.0';work_item_id='hook-test';status='exact';project_root=$TempRoot;allowed_paths=@('src/**');allowed_command_patterns=@('^npm\s+test$')}
  $ScopePath = Join-Path $TempRoot '.agy\EXECUTION_SCOPE.json'
  [IO.File]::WriteAllText($ScopePath,($Scope | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
  $Lease = [ordered]@{schema_version='1.0.0';lease_id='lease-hook-test';status='active';work_item_id='hook-test';goal_epoch=1;project_root=$TempRoot;worktree_root=$TempRoot;branch='main';baseline_head=$Head;owner_goal_sha256=(Get-TextSha 'Hook test');execution_scope_sha256=(Get-FileSha $ScopePath);allowed_paths=@('src/**');allowed_command_patterns=@('^npm\s+test$');first_write_started=$false}
  $Firewall = [ordered]@{schema_version='1.0.0';status='active';work_item_id='hook-test';stage_profile='general';protected_path_patterns=@();algorithm_repair_authorized=$false}
  foreach ($Pair in @(@('WORK_ITEM.json',$WorkItem),@('EXECUTION_LEASE.json',$Lease),@('STAGE_FIREWALL.json',$Firewall))) {[IO.File]::WriteAllText((Join-Path $TempRoot ('.agy\' + $Pair[0])),($Pair[1] | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))}
  $WorkTx=[ordered]@{schema_version='1.0.0';status='committed';work_item_id='hook-test';goal_epoch=1;files=@{};committed_at_utc=$Now}
  [IO.File]::WriteAllText((Join-Path $TempRoot '.agy\WORK_ITEM_TRANSACTION.json'),($WorkTx|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  $AuthorityFiles=[ordered]@{};foreach($Name in @('EXECUTION_SCOPE.json','EXECUTION_LEASE.json','STAGE_FIREWALL.json')){$AuthorityFiles[$Name]=[ordered]@{sha256=(Get-FileSha (Join-Path $TempRoot ('.agy\'+$Name)))}}
  $AuthorityTx=[ordered]@{schema_version='1.0.0';status='committed';work_item_id='hook-test';goal_epoch=1;lease_id='lease-hook-test';files=$AuthorityFiles;committed_at_utc=$Now}
  [IO.File]::WriteAllText((Join-Path $TempRoot '.agy\EXECUTION_AUTHORITY_TRANSACTION.json'),($AuthorityTx|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
  $AllowedPath = Join-Path $TempRoot 'src\ok.ts'
  $DeniedPath = Join-Path $TempRoot 'outside.ts'
  $Base = @{conversationId='hook-contract';workspacePaths=@($TempRoot);stepIdx=1}
  $AllowedInput = $Base.Clone(); $AllowedInput.toolCall = @{name='write_to_file';args=@{TargetFile=$AllowedPath}}
  $AllowedOutput = ($AllowedInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook prewrite | ConvertFrom-Json
  if ($AllowedOutput.decision -ne 'allow') { throw "Expected allowed write, got: $($AllowedOutput | ConvertTo-Json -Compress)" }
  $LeaseAfter = Get-Content -LiteralPath (Join-Path $TempRoot '.agy\EXECUTION_LEASE.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($LeaseAfter.first_write_started -ne $true) { throw 'First-write state was not recorded before the write.' }
  $DeniedInput = $Base.Clone(); $DeniedInput.stepIdx = 2; $DeniedInput.toolCall = @{name='write_to_file';args=@{TargetFile=$DeniedPath}}
  $DeniedOutput = ($DeniedInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook prewrite | ConvertFrom-Json
  if ($DeniedOutput.decision -ne 'deny') { throw 'Write outside lease was not denied.' }
  $DestructiveInput = $Base.Clone(); $DestructiveInput.stepIdx = 3; $DestructiveInput.toolCall = @{name='run_command';args=@{CommandLine='git reset --hard HEAD';Cwd=$TempRoot}}
  $DestructiveOutput = ($DestructiveInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook precommand | ConvertFrom-Json
  if ($DestructiveOutput.decision -ne 'force_ask') { throw 'Destructive command did not require an owner decision.' }
  $UnscopedInput = $Base.Clone(); $UnscopedInput.stepIdx = 4; $UnscopedInput.toolCall = @{name='run_command';args=@{CommandLine='npm run arbitrary-write';Cwd=$TempRoot}}
  $UnscopedOutput = ($UnscopedInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook precommand | ConvertFrom-Json
  if ($UnscopedOutput.decision -ne 'deny') { throw 'Command outside exact command scope was not denied.' }
  $BuildInput = $Base.Clone(); $BuildInput.stepIdx = 5; $BuildInput.toolCall = @{name='run_command';args=@{CommandLine='npm run build';Cwd=$TempRoot}}
  $BuildOutput = ($BuildInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook precommand | ConvertFrom-Json
  if ($BuildOutput.decision -ne 'deny') { throw 'Build command was incorrectly treated as read-only.' }
  $Next = [ordered]@{schema_version='1.0.0';work_item_id='hook-test';route='/fixcritical';auto_continue=$true;owner_decision_required=$false;updated_at_utc=$Now}
  $Progress = [ordered]@{schema_version='1.1.0';work_item_id='hook-test';status='progressing';observations_count=1;consecutive_no_progress=0;same_failure_count=0;owner_decision_required=$false;updated_at_utc=$Now;history=@()}
  [IO.File]::WriteAllText((Join-Path $TempRoot '.agy\NEXT_ACTION.json'),($Next | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $TempRoot '.agy\PROGRESS_STATE.json'),($Progress | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  $StopInput = @{conversationId='hook-contract';workspacePaths=@($TempRoot);fullyIdle=$true;terminationReason='model_stop';executionNum=1}
  $StopOutput = ($StopInput | ConvertTo-Json -Depth 10 -Compress) | & $Node $Hook stop | ConvertFrom-Json
  if ($StopOutput.decision -ne 'continue') { throw 'Stop hook did not auto-continue a progressing work item.' }
  $Progress.status = 'stalled'; $Progress.consecutive_no_progress = 2
  [IO.File]::WriteAllText((Join-Path $TempRoot '.agy\PROGRESS_STATE.json'),($Progress | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  $StalledOutput = ($StopInput | ConvertTo-Json -Depth 10 -Compress) | & $Node $Hook stop | ConvertFrom-Json
  if ($StalledOutput.decision -ne 'stop') { throw 'Stalled work item was not stopped.' }
  Write-Host 'Hook contract OK.'
} finally { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
