[CmdletBinding()]
param([string]$ProjectRoot='.',[switch]$Apply)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Agy=Join-Path $Root '.agy'
. (Join-Path $PSScriptRoot '..\common\NativeProcess.ps1')
$Lease=Get-Content -LiteralPath (Join-Path $Agy 'EXECUTION_LEASE.json') -Raw -Encoding UTF8|ConvertFrom-Json
function Normalize-Relative([string]$Value){$Normalized=($Value-replace'\\','/').Trim();while($Normalized.StartsWith('./',[StringComparison]::Ordinal)){$Normalized=$Normalized.Substring(2)};return $Normalized}
function Matches-Allowed([string]$Relative,[object[]]$Patterns){
  foreach($PatternValue in $Patterns){
    $Pattern=Normalize-Relative ([string]$PatternValue)
    if($Pattern.EndsWith('/**')){$Prefix=$Pattern.Substring(0,$Pattern.Length-3).TrimEnd('/');if($Relative-eq$Prefix-or$Relative.StartsWith($Prefix+'/',[StringComparison]::OrdinalIgnoreCase)){return $true}}
    elseif([Management.Automation.WildcardPattern]::new($Pattern,[Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($Relative)){return $true}
  }
  return $false
}
$StatusResult=Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-c','core.quotepath=false','-C',$Root,'status','--porcelain=v2','-z','--untracked-files=all')
Assert-AgenticNativeSuccess -Result $StatusResult -Description 'git status'
$Raw=@(Split-AgenticNulList -Text $StatusResult.StdOut)
$Changed=New-Object System.Collections.Generic.List[object]
for($Index=0;$Index-lt$Raw.Count;$Index++){
  $Record=[string]$Raw[$Index]
  $Status=$null;$Name=$null
  if($Record.StartsWith('? ')){$Status='??';$Name=$Record.Substring(2)}
  elseif($Record.StartsWith('1 ')){
    $Match=[regex]::Match($Record,'^1 (?<xy>..) [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ (?<path>.*)$',[Text.RegularExpressions.RegexOptions]::Singleline)
    if($Match.Success){$Status=$Match.Groups['xy'].Value;$Name=$Match.Groups['path'].Value}
  }
  elseif($Record.StartsWith('2 ')){
    $Match=[regex]::Match($Record,'^2 (?<xy>..) [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ (?<path>.*)$',[Text.RegularExpressions.RegexOptions]::Singleline)
    if($Match.Success){$Status=$Match.Groups['xy'].Value;$Name=$Match.Groups['path'].Value;$Index++}
  }
  if($null-eq$Name){throw "Unsupported Git porcelain v2 record: $Record"}
  $Relative=Normalize-Relative $Name
  if($Relative){$Changed.Add([ordered]@{status=$Status;path=$Relative})|Out-Null}
}
$Candidate=New-Object System.Collections.Generic.List[object]
$Ambient=New-Object System.Collections.Generic.List[object]
foreach($Entry in @($Changed.ToArray() | Sort-Object path -Unique)){
  if(Matches-Allowed $Entry.path @($Lease.allowed_paths)){
    $Full=Join-Path $Root ($Entry.path-replace'/','\')
    if(Test-Path -LiteralPath $Full -PathType Leaf){$Item=Get-Item -LiteralPath $Full;$Candidate.Add([ordered]@{status=$Entry.status;path=$Entry.path;exists=$true;size_bytes=[int64]$Item.Length;sha256=(Get-FileHash -LiteralPath $Full -Algorithm SHA256).Hash.ToLowerInvariant()})|Out-Null}
    else{$Candidate.Add([ordered]@{status=$Entry.status;path=$Entry.path;exists=$false;size_bytes=$null;sha256=$null})|Out-Null}
  }else{$Ambient.Add($Entry)|Out-Null}
}
$ControlNames=@('WORK_ITEM.json','WORK_ITEM_TRANSACTION.json','EXECUTION_SCOPE.json','EXECUTION_LEASE.json','EXECUTION_AUTHORITY_TRANSACTION.json','STAGE_FIREWALL.json','RUNTIME_HANDSHAKE.json','FINDINGS.json','FINDING_DELTA.json','REPAIR_DELTA.json','PROGRESS_STATE.json','NEXT_ACTION.json','AUDIT_COVERAGE_MATRIX.json','REVIEWER_ATTESTATION.json')
$Control=New-Object System.Collections.Generic.List[object]
foreach($Name in $ControlNames){$Full=Join-Path $Agy $Name;if(Test-Path -LiteralPath $Full -PathType Leaf){$Item=Get-Item -LiteralPath $Full;$Control.Add([ordered]@{path='.agy/'+$Name;size_bytes=[int64]$Item.Length;sha256=(Get-FileHash -LiteralPath $Full -Algorithm SHA256).Hash.ToLowerInvariant()})|Out-Null}}
$HeadResult=Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Root,'rev-parse','HEAD')
Assert-AgenticNativeSuccess -Result $HeadResult -Description 'git rev-parse'
$Head=$HeadResult.StdOut.Trim()
$Manifest=[ordered]@{schema_version='1.1.0';work_item_id=[string]$Lease.work_item_id;lease_id=[string]$Lease.lease_id;branch=[string]$Lease.branch;head=$Head;candidate_files=$Candidate.ToArray();control_plane_files=$Control.ToArray();ambient_git_status=$Ambient.ToArray();generated_at_utc=(Get-Date).ToUniversalTime().ToString('o')}
$Json=$Manifest|ConvertTo-Json -Depth 40
$Bytes=[Text.Encoding]::UTF8.GetBytes($Json);$Hasher=[Security.Cryptography.SHA256]::Create();try{$Hash=([Convert]::ToHexString($Hasher.ComputeHash($Bytes))).ToLowerInvariant()}finally{$Hasher.Dispose()}
$Status=[ordered]@{schema_version='1.1.0';status='current';manifest_path='.agy/CANDIDATE_MANIFEST.json';manifest_sha256=$Hash;candidate_file_count=$Candidate.Count;ambient_file_count=$Ambient.Count;invalidated_by=@();updated_at_utc=(Get-Date).ToUniversalTime().ToString('o')}
if($Apply){$Utf8=[Text.UTF8Encoding]::new($false);[IO.File]::WriteAllText((Join-Path $Agy 'CANDIDATE_MANIFEST.json'),$Json,$Utf8);[IO.File]::WriteAllText((Join-Path $Agy 'CANDIDATE_MANIFEST_STATUS.json'),($Status|ConvertTo-Json -Depth 10),$Utf8);Write-Host "Candidate manifest published for $($Candidate.Count) leased changed files. Ambient changes: $($Ambient.Count)."}else{[ordered]@{manifest=$Manifest;status=$Status}|ConvertTo-Json -Depth 50}
