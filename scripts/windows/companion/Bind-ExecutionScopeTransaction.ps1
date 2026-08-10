[CmdletBinding()]
param(
  [string]$ProjectRoot='.',
  [Parameter(Mandatory=$true)][string[]]$AllowedPaths,
  [string[]]$AllowedCommandPatterns=@(),
  [AllowNull()][AllowEmptyString()][string]$Route=$null,
  [switch]$AuthorizeAlgorithmRepair,
  [string[]]$FindingIds=@(),
  [switch]$Apply
)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy=Join-Path $Root '.agy'
. (Join-Path $PSScriptRoot '..\common\NativeProcess.ps1')
function Set-JsonProperty([object]$Object,[string]$Name,[object]$Value){$Property=$Object.PSObject.Properties[$Name];if($null-eq$Property){$Object|Add-Member -NotePropertyName $Name -NotePropertyValue $Value}else{$Property.Value=$Value}}
$Wi=Get-Content -LiteralPath (Join-Path $Agy 'WORK_ITEM.json') -Raw -Encoding UTF8|ConvertFrom-Json
$WorkTx=Get-Content -LiteralPath (Join-Path $Agy 'WORK_ITEM_TRANSACTION.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($WorkTx.status-ne'committed'-or[string]$WorkTx.work_item_id-ne[string]$Wi.work_item_id){throw 'Work-item transaction is not committed.'}
$AllowedRoutes=@('/nextphase','/fixcritical','/auditphase','/fastpatch','/shipcheck')
if([string]::IsNullOrWhiteSpace($Route)){
  $NextPath=Join-Path $Agy 'NEXT_ACTION.json'
  if(Test-Path -LiteralPath $NextPath -PathType Leaf){$Route=[string](Get-Content -LiteralPath $NextPath -Raw -Encoding UTF8|ConvertFrom-Json).route}
}
if($Route-notin$AllowedRoutes){throw "A valid current route is required. Found: $Route"}
$Now=(Get-Date).ToUniversalTime().ToString('o')
$BranchResult=Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Root,'branch','--show-current');Assert-AgenticNativeSuccess -Result $BranchResult -Description 'git branch';$Branch=$BranchResult.StdOut.Trim();if([string]::IsNullOrWhiteSpace($Branch)){throw 'Git branch unavailable.'}
$HeadResult=Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Root,'rev-parse','HEAD');Assert-AgenticNativeSuccess -Result $HeadResult -Description 'git rev-parse HEAD';$Head=$HeadResult.StdOut.Trim()
$GitRootResult=Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Root,'rev-parse','--show-toplevel');Assert-AgenticNativeSuccess -Result $GitRootResult -Description 'git rev-parse root';$GitRoot=$GitRootResult.StdOut.Trim()
if(([IO.Path]::GetFullPath($GitRoot)).TrimEnd('\')-ne([IO.Path]::GetFullPath($Root)).TrimEnd('\')){throw 'Project root must be the exact Git worktree root.'}
$GitStatusResult=Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Root,'status','--porcelain=v1','-z','--untracked-files=all');Assert-AgenticNativeSuccess -Result $GitStatusResult -Description 'git status';$GitDirty=($GitStatusResult.StdOut.Length-gt0)
function Get-TextSha([string]$Text){$Bytes=[Text.Encoding]::UTF8.GetBytes($Text);$Hash=[Security.Cryptography.SHA256]::Create();try{return([Convert]::ToHexString($Hash.ComputeHash($Bytes))).ToLowerInvariant()}finally{$Hash.Dispose()}}
function Get-FileSha([string]$Path){return(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
$Normalized=@($AllowedPaths|ForEach-Object{$Value=([string]$_ -replace'\\','/').Trim();while($Value.StartsWith('./',[StringComparison]::Ordinal)){$Value=$Value.Substring(2)};$Value}|Where-Object{$_}|Sort-Object -Unique)
if($Normalized.Count-eq0){throw 'AllowedPaths cannot be empty.'}
$Scope=[ordered]@{schema_version='1.1.0';work_item_id=[string]$Wi.work_item_id;status='exact';project_root=$Root;allowed_paths=$Normalized;forbidden_paths=@();forbidden_domains=@();allowed_command_patterns=@($AllowedCommandPatterns|Sort-Object -Unique);route=$Route;discovered_at_utc=$Now;external_drift=$false}
$GoalHash=Get-TextSha ([string]$Wi.goal)
$Lease=[ordered]@{schema_version='1.1.0';lease_id='lease-'+([guid]::NewGuid().ToString('N'));status='active';work_item_id=[string]$Wi.work_item_id;goal_epoch=[int]$Wi.goal_epoch;assurance_mode=[string]$Wi.assurance_mode;project_root=$Root;worktree_root=$GitRoot;branch=$Branch;baseline_head=$Head;owner_goal_sha256=$GoalHash;execution_scope_sha256=$null;allowed_paths=$Scope.allowed_paths;allowed_command_patterns=$Scope.allowed_command_patterns;route=$Route;forbidden_domains=@();stage_profile=[string]$Wi.stage_profile;first_write_started=$false;first_write_started_at_utc=$null;issued_at_utc=$Now;invalidated_at_utc=$null;invalidation_reasons=@()}
$Firewall=Get-Content -LiteralPath (Join-Path $Agy 'STAGE_FIREWALL.json') -Raw -Encoding UTF8|ConvertFrom-Json
Set-JsonProperty -Object $Firewall -Name 'status' -Value 'active'
Set-JsonProperty -Object $Firewall -Name 'work_item_id' -Value ([string]$Wi.work_item_id)
Set-JsonProperty -Object $Firewall -Name 'algorithm_repair_authorized' -Value ([bool]$AuthorizeAlgorithmRepair)
Set-JsonProperty -Object $Firewall -Name 'algorithm_repair_finding_ids' -Value @($FindingIds|Sort-Object -Unique)
Set-JsonProperty -Object $Firewall -Name 'analytical_baseline_head' -Value $Head
Set-JsonProperty -Object $Firewall -Name 'generated_at_utc' -Value $Now
$Handshake=[ordered]@{schema_version='1.2.0';generated_at_utc=$Now;project_root=$Root;git=[ordered]@{branch=$Branch;head_commit=$Head;git_state=if($GitDirty){'dirty'}else{'clean'}};installed=[ordered]@{package_version='1.2.20';runtime_version='1.2.20';companion_version='1.2.20'};work_item=[ordered]@{work_item_id=[string]$Wi.work_item_id;goal_epoch=[int]$Wi.goal_epoch;status='active'};routing=[ordered]@{routing_valid=$true;resolved_commands_allowed_now=@($Route);next_required_command=$Route;product_execution_allowed=($Route-in@('/nextphase','/fixcritical','/fastpatch'));release_execution_allowed=($Route-eq'/shipcheck')};execution_lease_id=$Lease.lease_id;progress_guard=[ordered]@{numeric_repair_budget=$false;auto_continue_while_progress=$true;consecutive_no_progress_limit=2;same_failure_limit=2}}
if(-not$Apply){[ordered]@{scope=$Scope;lease=$Lease;firewall=$Firewall;handshake=$Handshake}|ConvertTo-Json -Depth 50;exit 0}
$Tx=Join-Path $Agy ('.scope-transaction-'+[guid]::NewGuid().ToString('N'))
$History=Join-Path $Agy ('history\execution-authority-transactions\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $Tx|Out-Null
$Utf8=[Text.UTF8Encoding]::new($false)
$Names=@('EXECUTION_SCOPE.json','EXECUTION_LEASE.json','STAGE_FIREWALL.json','RUNTIME_HANDSHAKE.json')
try{
 [IO.File]::WriteAllText((Join-Path $Tx 'EXECUTION_SCOPE.json'),($Scope|ConvertTo-Json -Depth 50),$Utf8)
 $Lease.execution_scope_sha256=Get-FileSha (Join-Path $Tx 'EXECUTION_SCOPE.json')
 foreach($Pair in @(@('EXECUTION_LEASE.json',$Lease),@('STAGE_FIREWALL.json',$Firewall),@('RUNTIME_HANDSHAKE.json',$Handshake))){[IO.File]::WriteAllText((Join-Path $Tx $Pair[0]),($Pair[1]|ConvertTo-Json -Depth 50),$Utf8)}
 $Files=[ordered]@{};foreach($Name in $Names){$Files[$Name]=[ordered]@{sha256=Get-FileSha (Join-Path $Tx $Name)}}
 $Receipt=[ordered]@{schema_version='1.1.0';status='committed';transaction_id='execution-authority-'+([guid]::NewGuid().ToString('N'));work_item_id=[string]$Wi.work_item_id;goal_epoch=[int]$Wi.goal_epoch;lease_id=[string]$Lease.lease_id;branch=$Branch;baseline_head=$Head;route=$Route;files=$Files;committed_at_utc=$Now}
 [IO.File]::WriteAllText((Join-Path $Tx 'EXECUTION_AUTHORITY_TRANSACTION.json'),($Receipt|ConvertTo-Json -Depth 20),$Utf8)
 New-Item -ItemType Directory -Force $History|Out-Null
 foreach($Name in $Names+@('EXECUTION_AUTHORITY_TRANSACTION.json')){$Current=Join-Path $Agy $Name;if(Test-Path -LiteralPath $Current -PathType Leaf){Copy-Item -LiteralPath $Current -Destination (Join-Path $History $Name) -Force}}
 foreach($Name in $Names){Move-Item -LiteralPath (Join-Path $Tx $Name) -Destination (Join-Path $Agy $Name) -Force}
 Move-Item -LiteralPath (Join-Path $Tx 'EXECUTION_AUTHORITY_TRANSACTION.json') -Destination (Join-Path $Agy 'EXECUTION_AUTHORITY_TRANSACTION.json') -Force
 & (Join-Path $Root 'scripts\windows\companion\Test-ExecutionLease.ps1') -ProjectRoot $Root -BeforeWrite
 if($LASTEXITCODE-ne0){throw 'Published execution authority failed validation.'}
 Write-Host 'Exact execution scope, lease, firewall and route published atomically.'
}finally{Remove-Item $Tx -Recurse -Force -ErrorAction SilentlyContinue}
