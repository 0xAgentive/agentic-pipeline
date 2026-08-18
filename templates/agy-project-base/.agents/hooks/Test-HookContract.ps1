[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$PathSeparators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
function Test-UnsafeTemporaryBase {
  param([Parameter(Mandatory = $true)][string]$Path)
  $Full = [IO.Path]::GetFullPath($Path)
  $Normalized = $Full.TrimEnd($PathSeparators)
  $VolumeRoot = [IO.Path]::GetPathRoot($Full)
  if ([string]::IsNullOrWhiteSpace($Normalized) -or [string]::IsNullOrWhiteSpace($VolumeRoot)) { return $true }
  $NormalizedVolumeRoot = [IO.Path]::GetFullPath($VolumeRoot).TrimEnd($PathSeparators)
  return $Normalized.Equals($NormalizedVolumeRoot, $PathComparison)
}
$Node = (Get-Command node -ErrorAction Stop).Source
$Hook = Join-Path $ProjectRoot '.agents/hooks/agentic_runtime_hook.cjs'
$HooksJson = Join-Path $ProjectRoot '.agents/hooks.json'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) { throw 'Active Node hook is missing.' }
if (-not (Test-Path -LiteralPath $HooksJson -PathType Leaf)) { throw 'hooks.json is missing.' }
$Config = Get-Content -LiteralPath $HooksJson -Raw -Encoding UTF8 | ConvertFrom-Json
$Group = $Config.'agentic-owner-autonomy'
if (-not $Group -or $Group.enabled -ne $true) { throw 'Owner-autonomy hook registration is missing or disabled.' }
foreach ($EventName in @('PreToolUse','PostToolUse','PreInvocation','Stop')) {
  if (-not $Group.PSObject.Properties[$EventName] -or @($Group.$EventName).Count -eq 0) { throw "Hook event missing: $EventName" }
}
$ConfiguredCommands = @(
  @($Group.PreToolUse) | ForEach-Object { @($_.hooks) | ForEach-Object { [string]$_.command } }
  @($Group.PostToolUse) | ForEach-Object { @($_.hooks) | ForEach-Object { [string]$_.command } }
  @($Group.PreInvocation) | ForEach-Object { [string]$_.command }
  @($Group.Stop) | ForEach-Object { [string]$_.command }
)
$ExpectedCommands = @(
  'node hooks/agentic_runtime_hook.cjs prewrite',
  'node hooks/agentic_runtime_hook.cjs precommand',
  'node hooks/agentic_runtime_hook.cjs postwrite',
  'node hooks/agentic_runtime_hook.cjs postcommand',
  'node hooks/agentic_runtime_hook.cjs preinvocation',
  'node hooks/agentic_runtime_hook.cjs stop'
)
if ((@($ConfiguredCommands | Sort-Object) -join "`n") -cne (@($ExpectedCommands | Sort-Object) -join "`n")) {
  throw 'Hook commands do not exactly match the paths resolved from the Antigravity .agents working directory.'
}
if (@($ConfiguredCommands | Where-Object { $_ -match '(?i)(?:^|\s)\.agents[\\/]hooks[\\/]' }).Count -gt 0) {
  throw 'Hook command duplicates the .agents working-directory segment.'
}
$ConfiguredStopCommand = [string]@($Group.Stop)[0].command
$ConfiguredStopMatch = [regex]::Match($ConfiguredStopCommand, '^node (?<script>hooks/agentic_runtime_hook\.cjs) (?<event>stop)$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
if (-not $ConfiguredStopMatch.Success) { throw 'Stop hook command cannot be invoked safely by the cwd regression.' }
$TempBaseFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (Test-UnsafeTemporaryBase -Path $TempBaseFull) { throw "Unsafe hook-contract temporary base: $TempBaseFull" }
$TempBase = $TempBaseFull.TrimEnd($PathSeparators)
$TempVolumeRoot = [IO.Path]::GetPathRoot($TempBaseFull)
if (-not (Test-UnsafeTemporaryBase -Path $TempVolumeRoot)) { throw "Hook-contract volume-root rejection probe failed: $TempVolumeRoot" }
$TempBasePrefix = $TempBase + [IO.Path]::DirectorySeparatorChar
$TempRootName = 'agentic-hook-contract-' + [guid]::NewGuid().ToString('N')
$TempRoot = [IO.Path]::GetFullPath((Join-Path $TempBase $TempRootName)).TrimEnd($PathSeparators)
if (-not $TempRoot.StartsWith($TempBasePrefix, $PathComparison) -or $TempRoot.Equals($TempBase, $PathComparison) -or (Test-UnsafeTemporaryBase -Path $TempRoot) -or (Split-Path -Leaf $TempRoot) -cnotmatch '^agentic-hook-contract-[0-9a-f]{32}$') { throw "Unsafe hook-contract temporary root: $TempRoot" }
try {
  New-Item -ItemType Directory -Force (Join-Path $TempRoot '.agy') | Out-Null
  $TempAgentsRoot = New-Item -ItemType Directory -Force (Join-Path $TempRoot '.agents')
  $TempHookRoot = New-Item -ItemType Directory -Force (Join-Path $TempAgentsRoot.FullName 'hooks')
  $TempHook = Join-Path $TempHookRoot.FullName 'agentic_runtime_hook.cjs'
  Copy-Item -LiteralPath $Hook -Destination $TempHook
  New-Item -ItemType Directory -Force (Join-Path $TempRoot 'src') | Out-Null
  $CwdInput = @{conversationId='hook-cwd-contract';workspacePaths=@($TempRoot);fullyIdle=$false;terminationReason='model_stop'} | ConvertTo-Json -Depth 10 -Compress
  Push-Location -LiteralPath $TempAgentsRoot.FullName
  try {
    $CwdRawOutput = @($CwdInput | & $Node $ConfiguredStopMatch.Groups['script'].Value $ConfiguredStopMatch.Groups['event'].Value 2>&1)
    $CwdExitCode = $LASTEXITCODE
  }
  finally { Pop-Location }
  if ($CwdExitCode -ne 0) { throw "Configured Stop hook failed from the Antigravity .agents cwd: $($CwdRawOutput -join [Environment]::NewLine)" }
  $CwdOutput = ($CwdRawOutput -join "`n") | ConvertFrom-Json
  if ([string]$CwdOutput.decision -ne 'stop') { throw 'Configured Stop hook returned an invalid result from the Antigravity .agents cwd.' }
  $ResolvedConfiguredHook = (Resolve-Path -LiteralPath (Join-Path $TempAgentsRoot.FullName $ConfiguredStopMatch.Groups['script'].Value)).Path
  if (-not $ResolvedConfiguredHook.Equals($TempHook, $PathComparison)) { throw 'Configured Stop hook did not resolve to .agents/hooks/agentic_runtime_hook.cjs.' }
  [IO.File]::WriteAllText((Join-Path $TempRoot 'src/base.ts'),'export const base = true;',[Text.UTF8Encoding]::new($false))
  & git -C $TempRoot init -b main | Out-Null
  & git -C $TempRoot -c user.name='Hook Contract' -c user.email='hook@local.invalid' add --all
  & git -C $TempRoot -c user.name='Hook Contract' -c user.email='hook@local.invalid' -c commit.gpgsign=false commit -m baseline | Out-Null
  $Head = (& git -C $TempRoot rev-parse HEAD).Trim()
  $Now = (Get-Date).ToUniversalTime().ToString('o')
  function Get-TextSha([string]$Text){$Bytes=[Text.Encoding]::UTF8.GetBytes($Text);$Hash=[Security.Cryptography.SHA256]::Create();try{return([Convert]::ToHexString($Hash.ComputeHash($Bytes))).ToLowerInvariant()}finally{$Hash.Dispose()}}
  function Get-FileSha([string]$Path){return(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
  $WorkItem = [ordered]@{schema_version='1.0.0';work_item_id='hook-test';goal_epoch=1;goal='Hook test';assurance_mode='guarded';status='active';owner_approved=$true;owner_interaction_policy='hard_stop_only';scope_binding='exact';created_at_utc=$Now;updated_at_utc=$Now;stage_profile='general'}
  $Scope = [ordered]@{schema_version='1.0.0';work_item_id='hook-test';status='exact';project_root=$TempRoot;allowed_paths=@('src/**');allowed_command_patterns=@('^npm\s+test$')}
  $ScopePath = Join-Path $TempRoot '.agy/EXECUTION_SCOPE.json'
  [IO.File]::WriteAllText($ScopePath,($Scope | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
  $Lease = [ordered]@{schema_version='1.0.0';lease_id='lease-hook-test';status='active';work_item_id='hook-test';goal_epoch=1;project_root=$TempRoot;worktree_root=$TempRoot;branch='main';baseline_head=$Head;owner_goal_sha256=(Get-TextSha 'Hook test');execution_scope_sha256=(Get-FileSha $ScopePath);allowed_paths=@('src/**');allowed_command_patterns=@('^npm\s+test$');first_write_started=$false}
  $Firewall = [ordered]@{schema_version='1.0.0';status='active';work_item_id='hook-test';stage_profile='general';protected_path_patterns=@();algorithm_repair_authorized=$false}
  foreach ($Pair in @(@('WORK_ITEM.json',$WorkItem),@('EXECUTION_LEASE.json',$Lease),@('STAGE_FIREWALL.json',$Firewall))) {[IO.File]::WriteAllText((Join-Path (Join-Path $TempRoot '.agy') $Pair[0]),($Pair[1] | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))}
  $WorkTx=[ordered]@{schema_version='1.0.0';status='committed';work_item_id='hook-test';goal_epoch=1;files=@{};committed_at_utc=$Now}
  [IO.File]::WriteAllText((Join-Path $TempRoot '.agy/WORK_ITEM_TRANSACTION.json'),($WorkTx|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  $AuthorityFiles=[ordered]@{};foreach($Name in @('EXECUTION_SCOPE.json','EXECUTION_LEASE.json','STAGE_FIREWALL.json')){$AuthorityFiles[$Name]=[ordered]@{sha256=(Get-FileSha (Join-Path (Join-Path $TempRoot '.agy') $Name))}}
  $AuthorityTx=[ordered]@{schema_version='1.0.0';status='committed';work_item_id='hook-test';goal_epoch=1;lease_id='lease-hook-test';files=$AuthorityFiles;committed_at_utc=$Now}
  [IO.File]::WriteAllText((Join-Path $TempRoot '.agy/EXECUTION_AUTHORITY_TRANSACTION.json'),($AuthorityTx|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
  $AllowedPath = Join-Path $TempRoot 'src/ok.ts'
  $DeniedPath = Join-Path $TempRoot 'outside.ts'
  $Base = @{conversationId='hook-contract';workspacePaths=@($TempRoot);stepIdx=1}
  $AllowedInput = $Base.Clone(); $AllowedInput.toolCall = @{name='write_to_file';args=@{TargetFile=$AllowedPath}}
  $AllowedOutput = ($AllowedInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook prewrite | ConvertFrom-Json
  if ($AllowedOutput.decision -ne 'allow') { throw "Expected allowed write, got: $($AllowedOutput | ConvertTo-Json -Compress)" }
  $LeaseAfter = Get-Content -LiteralPath (Join-Path $TempRoot '.agy/EXECUTION_LEASE.json') -Raw -Encoding UTF8 | ConvertFrom-Json
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
  $NestedCompilerInput = $Base.Clone(); $NestedCompilerInput.stepIdx = 6; $NestedCompilerInput.toolCall = @{name='run_command';args=@{CommandLine="pwsh -Command `"& './scripts/windows/companion/Compile-ResultAuthority.ps1'`"";Cwd=$TempRoot}}
  $NestedCompilerOutput = ($NestedCompilerInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook precommand | ConvertFrom-Json
  if ($NestedCompilerOutput.decision -ne 'deny') { throw 'Nested or interactive result-authority invocation was not denied.' }
  $MissingReceiptInput = $Base.Clone(); $MissingReceiptInput.stepIdx = 7; $MissingReceiptInput.toolCall = @{name='run_command';args=@{CommandLine="pwsh -NoProfile -NonInteractive -File scripts/windows/companion/Compile-ResultAuthority.ps1 -ProjectRoot `"$TempRoot`" -TimeoutSeconds 120 -Apply";Cwd=$TempRoot}}
  $MissingReceiptOutput = ($MissingReceiptInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook precommand | ConvertFrom-Json
  if ($MissingReceiptOutput.decision -ne 'deny') { throw 'Result-authority invocation without a receipt was not denied.' }
  $CompilerCommand = "pwsh -NoProfile -NonInteractive -File scripts/windows/companion/Compile-ResultAuthority.ps1 -ProjectRoot `"$TempRoot`" -VerificationReceiptPath .agy/receipt-input.json -TimeoutSeconds 120 -Apply"
  $CompilerInput = $Base.Clone(); $CompilerInput.stepIdx = 8; $CompilerInput.toolCall = @{name='run_command';args=@{CommandLine=$CompilerCommand;Cwd=$TempRoot}}
  $CompilerOutput = ($CompilerInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook precommand | ConvertFrom-Json
  if ($CompilerOutput.decision -ne 'allow') { throw "Exact bounded result-authority invocation was denied: $($CompilerOutput | ConvertTo-Json -Compress)" }
  $CandidateStatus = [ordered]@{schema_version='1.1.0';status='current';manifest_path='.agy/CANDIDATE_MANIFEST.json';manifest_sha256=('a' * 64);updated_at_utc=$Now}
  $CandidateStatusPath = Join-Path $TempRoot '.agy/CANDIDATE_MANIFEST_STATUS.json'
  [IO.File]::WriteAllText($CandidateStatusPath,($CandidateStatus | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  $CandidateStatusSha = Get-FileSha $CandidateStatusPath
  $CompilerRuntime = Join-Path $TempRoot '.agy/.runtime/result-authority'
  New-Item -ItemType Directory -Force -Path $CompilerRuntime | Out-Null
  $RunningStatus = [ordered]@{schema_version='1.0.0';state='running';deadline_at_utc=(Get-Date).ToUniversalTime().AddMinutes(2).ToString('o');updated_at_utc=$Now}
  [IO.File]::WriteAllText((Join-Path $CompilerRuntime 'status.json'),($RunningStatus | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  $ActiveWriteInput = $Base.Clone(); $ActiveWriteInput.stepIdx = 9; $ActiveWriteInput.toolCall = @{name='write_to_file';args=@{TargetFile=$AllowedPath}}
  $ActiveWriteOutput = ($ActiveWriteInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook prewrite | ConvertFrom-Json
  if ($ActiveWriteOutput.decision -ne 'deny') { throw 'Write was not frozen while result-authority compilation was active.' }
  $ActiveCommandInput = $Base.Clone(); $ActiveCommandInput.stepIdx = 10; $ActiveCommandInput.toolCall = @{name='run_command';args=@{CommandLine='npm test';Cwd=$TempRoot}}
  $ActiveCommandOutput = ($ActiveCommandInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook precommand | ConvertFrom-Json
  if ($ActiveCommandOutput.decision -ne 'deny') { throw 'Mutation-capable verification command was not frozen while compilation was active.' }
  $ActiveCompilerInput = $Base.Clone(); $ActiveCompilerInput.stepIdx = 11; $ActiveCompilerInput.toolCall = @{name='run_command';args=@{CommandLine=$CompilerCommand;Cwd=$TempRoot}}
  $ActiveCompilerOutput = ($ActiveCompilerInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook precommand | ConvertFrom-Json
  if ($ActiveCompilerOutput.decision -ne 'allow') { throw 'A same-contract compiler request was not allowed to coalesce.' }
  $CompilerPostInput = $ActiveCompilerInput.Clone(); $CompilerPostInput.error = $null
  ($CompilerPostInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook postcommand | Out-Null
  $CompilerLedger = @((Get-Content -LiteralPath (Join-Path $TempRoot '.agy/COMMAND_LEDGER.ndjson') -Encoding UTF8) | ForEach-Object { $_ | ConvertFrom-Json })
  $PendingLedger = $CompilerLedger[-1]
  if ($PendingLedger.success -ne $false -or [string]$PendingLedger.error -notmatch 'RESULT_AUTHORITY_COMPLETION_PENDING') { throw 'Post-command hook falsely recorded an active compiler as successful.' }
  if ((Get-FileSha $CandidateStatusPath) -cne $CandidateStatusSha) { throw 'Result-authority post hook invalidated the candidate manifest.' }
  $ActiveStopInput = @{conversationId='hook-contract';workspacePaths=@($TempRoot);fullyIdle=$true;terminationReason='model_stop';executionNum=1}
  $ActiveStopOutput = ($ActiveStopInput | ConvertTo-Json -Depth 10 -Compress) | & $Node $Hook stop | ConvertFrom-Json
  if ($ActiveStopOutput.decision -ne 'stop') { throw 'Stop hook auto-continued while result-authority compilation was active.' }
  $NotIdleStopInput = $ActiveStopInput.Clone(); $NotIdleStopInput.fullyIdle = $false
  $NotIdleStopOutput = ($NotIdleStopInput | ConvertTo-Json -Depth 10 -Compress) | & $Node $Hook stop | ConvertFrom-Json
  if ($NotIdleStopOutput.decision -ne 'stop') { throw 'Stop hook continued before true idle.' }
  $RunningStatus.state = 'completed'; $RunningStatus.deadline_at_utc = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o'); $RunningStatus.updated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  [IO.File]::WriteAllText((Join-Path $CompilerRuntime 'status.json'),($RunningStatus | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  $CompletedCompilerInput = $Base.Clone(); $CompletedCompilerInput.stepIdx = 12; $CompletedCompilerInput.toolCall = @{name='run_command';args=@{CommandLine=$CompilerCommand;Cwd=$TempRoot}}
  $CompletedCompilerOutput = ($CompletedCompilerInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook precommand | ConvertFrom-Json
  if ($CompletedCompilerOutput.decision -ne 'allow') { throw 'Compiler invocation was denied after prior completion.' }
  $RunningStatus.updated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  [IO.File]::WriteAllText((Join-Path $CompilerRuntime 'status.json'),($RunningStatus | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  $CompletedCompilerPost = $CompletedCompilerInput.Clone(); $CompletedCompilerPost.error = $null
  ($CompletedCompilerPost | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook postcommand | Out-Null
  $CompletedLedger = ((Get-Content -LiteralPath (Join-Path $TempRoot '.agy/COMMAND_LEDGER.ndjson') -Encoding UTF8)[-1] | ConvertFrom-Json)
  if ($CompletedLedger.success -ne $true -or -not [string]::IsNullOrEmpty([string]$CompletedLedger.error)) { throw 'Completed compiler was not recorded as successful.' }
  if ((Get-FileSha $CandidateStatusPath) -cne $CandidateStatusSha) { throw 'Completed compiler invalidated the candidate manifest.' }
  $StalePendingRoot = Join-Path $TempRoot '.agy/.hook_pending'
  New-Item -ItemType Directory -Force -Path $StalePendingRoot | Out-Null
  $StalePending = Join-Path $StalePendingRoot 'stale-999.json'
  [IO.File]::WriteAllText($StalePending,('{"kind":"command","data":{"resultAuthority":true,"command":"Compile-ResultAuthority.ps1"}}'),[Text.UTF8Encoding]::new($false))
  (Get-Item -LiteralPath $StalePending).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-20)
  $ReadInput = $Base.Clone(); $ReadInput.stepIdx = 13; $ReadInput.toolCall = @{name='run_command';args=@{CommandLine='git status';Cwd=$TempRoot}}
  $ReadOutput = ($ReadInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook precommand | ConvertFrom-Json
  if ($ReadOutput.decision -ne 'allow' -or (Test-Path -LiteralPath $StalePending)) { throw 'Stale compiler pending marker was not pruned safely.' }
  $PwshReadInput = $Base.Clone(); $PwshReadInput.stepIdx = 14; $PwshReadInput.toolCall = @{name='run_command';args=@{CommandLine='pwsh -NoProfile -Command "git status --porcelain"';Cwd=$TempRoot}}
  $PwshReadOutput = ($PwshReadInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook precommand | ConvertFrom-Json
  if ($PwshReadOutput.decision -ne 'allow') { throw 'pwsh -Command read-only command was denied.' }
  $PwshReadPost = $PwshReadInput.Clone(); $PwshReadPost.error = $null
  ($PwshReadPost | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook postcommand | Out-Null
  if ((Get-FileSha $CandidateStatusPath) -cne $CandidateStatusSha) { throw 'pwsh -Command read-only command invalidated candidate manifest status.' }
  $Next = [ordered]@{schema_version='1.0.0';work_item_id='hook-test';route='/fixcritical';auto_continue=$true;owner_decision_required=$false;updated_at_utc=$Now}
  $Progress = [ordered]@{schema_version='1.1.0';work_item_id='hook-test';status='progressing';observations_count=1;consecutive_no_progress=0;same_failure_count=0;owner_decision_required=$false;updated_at_utc=$Now;history=@()}
  [IO.File]::WriteAllText((Join-Path $TempRoot '.agy/NEXT_ACTION.json'),($Next | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $TempRoot '.agy/PROGRESS_STATE.json'),($Progress | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  $StopInput = @{conversationId='hook-contract';workspacePaths=@($TempRoot);fullyIdle=$true;terminationReason='model_stop';executionNum=1}
  $StopOutput = ($StopInput | ConvertTo-Json -Depth 10 -Compress) | & $Node $Hook stop | ConvertFrom-Json
  if ($StopOutput.decision -ne 'continue') { throw 'Stop hook did not auto-continue a progressing work item.' }
  # AP-PROD-001: Post-hook reconciliation tests
  # 1. Write ledger failure test
  $ReconDir = Join-Path $TempRoot '.agy\WRITE_LEDGER.ndjson'
  New-Item -ItemType Directory -Force -Path $ReconDir | Out-Null
  $PendingWriteFile = Join-Path $TempRoot '.agy\.hook_pending\recon-write-1.json'
  $PendingWriteBody = [ordered]@{ kind = 'write'; data = [ordered]@{ file = (Join-Path $TempRoot 'src/base.ts'); rel = 'src/base.ts' }; created_at_utc = (Get-Date).ToUniversalTime().ToString('o') }
  [IO.File]::WriteAllText($PendingWriteFile, ($PendingWriteBody | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
  $ReconWriteInput = @{ conversationId = 'recon-write'; workspacePaths = @($TempRoot); stepIdx = 1; toolCall = @{ name = 'write_to_file'; args = @{ TargetFile = (Join-Path $TempRoot 'src/base.ts') } }; error = $null }
  ($ReconWriteInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook postwrite | Out-Null
  $ReconMarkerPath = Join-Path $TempRoot '.agy\HOOK_RECONCILIATION_REQUIRED.json'
  if (-not (Test-Path -LiteralPath $ReconMarkerPath -PathType Leaf)) { throw 'Postwrite failure did not create HOOK_RECONCILIATION_REQUIRED.json.' }
  if (-not (Test-Path -LiteralPath $PendingWriteFile -PathType Leaf)) { throw 'Postwrite failure silently removed pending record.' }
  $StatusAfterRecon = (Get-Content -LiteralPath $CandidateStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json)
  if ([string]$StatusAfterRecon.status -ne 'reconciliation_required') { throw 'Postwrite failure did not set status to reconciliation_required.' }
  $StopDuringRecon = ($StopInput | ConvertTo-Json -Depth 10 -Compress) | & $Node $Hook stop | ConvertFrom-Json
  if ($StopDuringRecon.decision -ne 'stop') { throw 'Stop hook auto-continued while reconciliation was required.' }
  $PrewriteDuringRecon = ($Base.Clone() | ConvertTo-Json -Depth 20 -Compress)
  $PrewriteReconInput = @{ conversationId = 'recon-test'; workspacePaths = @($TempRoot); stepIdx = 20; toolCall = @{ name = 'write_to_file'; args = @{ TargetFile = (Join-Path $TempRoot 'src/base.ts') } } }
  $PrewriteReconOutput = ($PrewriteReconInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook prewrite | ConvertFrom-Json
  if ($PrewriteReconOutput.decision -ne 'deny') { throw 'Prewrite hook allowed write while reconciliation was required.' }

  # Recovery: Remove blocking directory, rerun postwrite, verify reconciliation is cleared
  Remove-Item -LiteralPath $ReconDir -Force
  ($ReconWriteInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook postwrite | Out-Null
  if (Test-Path -LiteralPath $ReconMarkerPath -PathType Leaf) { throw 'Successful postwrite did not clear HOOK_RECONCILIATION_REQUIRED.json.' }
  if (Test-Path -LiteralPath $PendingWriteFile -PathType Leaf) { throw 'Successful postwrite did not remove pending record.' }
  $StatusAfterFix = (Get-Content -LiteralPath $CandidateStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json)
  if ([string]$StatusAfterFix.status -ne 'invalidated') { throw 'Successful postwrite did not invalidate candidate manifest.' }

  # 2. Command ledger failure test
  $ReconCmdDir = Join-Path $TempRoot '.agy\COMMAND_LEDGER.ndjson'
  Remove-Item -LiteralPath $ReconCmdDir -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $ReconCmdDir | Out-Null
  $PendingCmdFile = Join-Path $TempRoot '.agy\.hook_pending\recon-cmd-1.json'
  $PendingCmdBody = [ordered]@{ kind = 'command'; data = [ordered]@{ command = 'npm test'; cwd = $TempRoot; readOnly = $false }; created_at_utc = (Get-Date).ToUniversalTime().ToString('o') }
  [IO.File]::WriteAllText($PendingCmdFile, ($PendingCmdBody | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
  $ReconCmdInput = @{ conversationId = 'recon-cmd'; workspacePaths = @($TempRoot); stepIdx = 1; toolCall = @{ name = 'run_command'; args = @{ CommandLine = 'npm test'; Cwd = $TempRoot } }; error = $null }
  ($ReconCmdInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook postcommand | Out-Null
  if (-not (Test-Path -LiteralPath $ReconMarkerPath -PathType Leaf)) { throw 'Postcommand failure did not create HOOK_RECONCILIATION_REQUIRED.json.' }
  if (-not (Test-Path -LiteralPath $PendingCmdFile -PathType Leaf)) { throw 'Postcommand failure silently removed pending record.' }
  Remove-Item -LiteralPath $ReconCmdDir -Force
  ($ReconCmdInput | ConvertTo-Json -Depth 20 -Compress) | & $Node $Hook postcommand | Out-Null
  if (Test-Path -LiteralPath $ReconMarkerPath -PathType Leaf) { throw 'Successful postcommand did not clear HOOK_RECONCILIATION_REQUIRED.json.' }
  if (Test-Path -LiteralPath $PendingCmdFile -PathType Leaf) { throw 'Successful postcommand did not remove pending record.' }

  Write-Host 'Hook contract OK.'
} finally {
  if (Test-Path -LiteralPath $TempRoot -PathType Container) {
    $ResolvedTemp = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TempRoot).Path).TrimEnd($PathSeparators)
    if (-not $ResolvedTemp.StartsWith($TempBasePrefix, $PathComparison) -or -not $ResolvedTemp.Equals($TempRoot, $PathComparison) -or $ResolvedTemp.Equals($TempBase, $PathComparison) -or (Test-UnsafeTemporaryBase -Path $ResolvedTemp) -or (Split-Path -Leaf $ResolvedTemp) -cnotmatch '^agentic-hook-contract-[0-9a-f]{32}$') { throw "Unsafe hook-contract cleanup target: $ResolvedTemp" }
    Remove-Item -LiteralPath $ResolvedTemp -Recurse -Force
  }
}
