Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
function Read-HookInput { $Raw=[Console]::In.ReadToEnd(); if([string]::IsNullOrWhiteSpace($Raw)){return [pscustomobject]@{}}; return ($Raw|ConvertFrom-Json) }
function Write-HookJson([object]$Value) { [Console]::Out.Write(($Value|ConvertTo-Json -Depth 30 -Compress)) }
function Resolve-ProjectRoot([object]$HookPayload,[string]$Candidate='') {
  $Candidates=New-Object System.Collections.Generic.List[string]
  if(-not [string]::IsNullOrWhiteSpace($Candidate)){[void]$Candidates.Add($Candidate)}
  foreach($W in @($HookPayload.workspacePaths)){if($W){[void]$Candidates.Add([string]$W)}}
  foreach($C in $Candidates){
    try{$P=[IO.Path]::GetFullPath($C);if(Test-Path -LiteralPath $P -PathType Leaf){$P=Split-Path -Parent $P}
      while($P){if((Test-Path -LiteralPath (Join-Path $P '.agy') -PathType Container)-and(Test-Path -LiteralPath (Join-Path $P '.agents') -PathType Container)){return $P};$Parent=Split-Path -Parent $P;if($Parent-eq$P){break};$P=$Parent}
    }catch{}
  }
  return $null
}
function Normalize-Rel([string]$Root,[string]$Path){$Full=[IO.Path]::GetFullPath($Path);$R=[IO.Path]::GetFullPath($Root).TrimEnd('\\','/');if(-not($Full-eq$R-or$Full.StartsWith($R+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))){throw 'PATH_OUTSIDE_PROJECT'};return [IO.Path]::GetRelativePath($R,$Full).Replace('\\','/')}
function Test-Pattern([string]$Value,[string]$Pattern){$P=$Pattern.Replace('\\','/').TrimStart('./');$W=[Management.Automation.WildcardPattern]::new($P,[Management.Automation.WildcardOptions]::IgnoreCase);return $W.IsMatch($Value)}

try{$HookPayload=Read-HookInput;$Cwd=[string]$HookPayload.toolCall.args.Cwd;$Root=Resolve-ProjectRoot $HookPayload $Cwd;if(-not$Root){Write-HookJson @{};exit 0};$Agy=Join-Path $Root '.agy';$Rec=[ordered]@{at_utc=(Get-Date).ToUniversalTime().ToString('o');tool='run_command';command=[string]$HookPayload.toolCall.args.CommandLine;cwd=$Cwd;error=[string]$HookPayload.error};[IO.File]::AppendAllText((Join-Path $Agy 'COMMAND_LEDGER.ndjson'),(($Rec|ConvertTo-Json -Compress)+[Environment]::NewLine),$Utf8NoBom);if([string]::IsNullOrWhiteSpace([string]$HookPayload.error)-and([string]$HookPayload.toolCall.args.CommandLine-notmatch'(?i)^\s*(git\s+(status|diff|rev-parse|log|show)|Get-|Test-|Select-|node\s+--check)')){$Status=[ordered]@{schema_version='1.0.0';status='invalidated';manifest_path=$null;invalidated_by=@('run_command');updated_at_utc=(Get-Date).ToUniversalTime().ToString('o')};[IO.File]::WriteAllText((Join-Path $Agy 'CANDIDATE_MANIFEST_STATUS.json'),($Status|ConvertTo-Json -Depth 10),$Utf8NoBom)};Write-HookJson @{} }catch{Write-HookJson @{}}
