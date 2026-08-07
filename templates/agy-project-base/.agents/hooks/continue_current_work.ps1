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

try{$HookPayload=Read-HookInput;if($HookPayload.fullyIdle-ne$true-or[string]$HookPayload.terminationReason-ne'model_stop'){Write-HookJson @{decision='stop'};exit 0};$Root=Resolve-ProjectRoot $HookPayload;if(-not$Root){Write-HookJson @{decision='stop'};exit 0};$NextPath=Join-Path $Root '.agy\NEXT_ACTION.json';$ProgressPath=Join-Path $Root '.agy\PROGRESS_STATE.json';if(!(Test-Path $NextPath)){Write-HookJson @{decision='stop'};exit 0};$Next=Get-Content $NextPath -Raw|ConvertFrom-Json;$Progress=if(Test-Path $ProgressPath){Get-Content $ProgressPath -Raw|ConvertFrom-Json}else{$null};if($Next.owner_decision_required-eq$true){Write-HookJson @{decision='stop'};exit 0};if($Progress-and$Progress.status-eq'stalled'){Write-HookJson @{decision='stop'};exit 0};if($Next.auto_continue-eq$true-and$Next.route){Write-HookJson @{decision='continue';reason=("Continue the active owner-approved work item automatically. Read .agy/NEXT_ACTION.json and execute route "+$Next.route+". Do not ask for permission because no true owner decision is required.")};exit 0};Write-HookJson @{decision='stop'} }catch{Write-HookJson @{decision='stop'}}
