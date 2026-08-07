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

try{$HookPayload=Read-HookInput;$Target=[string]$HookPayload.toolCall.args.TargetFile;$Root=Resolve-ProjectRoot $HookPayload $Target;if(-not$Root){Write-HookJson @{};exit 0};$Agy=Join-Path $Root '.agy';New-Item -ItemType Directory -Force $Agy|Out-Null;$Rel=Normalize-Rel $Root $Target;$Record=[ordered]@{at_utc=(Get-Date).ToUniversalTime().ToString('o');tool=[string]$HookPayload.toolCall.name;path=$Rel;success=[string]::IsNullOrWhiteSpace([string]$HookPayload.error);sha256=if(Test-Path $Target -PathType Leaf){(Get-FileHash $Target -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}};[IO.File]::AppendAllText((Join-Path $Agy 'WRITE_LEDGER.ndjson'),(($Record|ConvertTo-Json -Compress)+[Environment]::NewLine),$Utf8NoBom);$Status=[ordered]@{schema_version='1.0.0';status='invalidated';manifest_path=$null;invalidated_by=@($Rel);updated_at_utc=(Get-Date).ToUniversalTime().ToString('o')};[IO.File]::WriteAllText((Join-Path $Agy 'CANDIDATE_MANIFEST_STATUS.json'),($Status|ConvertTo-Json -Depth 10),$Utf8NoBom);Write-HookJson @{} }catch{Write-HookJson @{}}
