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

try{$HookPayload=Read-HookInput;$Root=Resolve-ProjectRoot $HookPayload;if(-not$Root){Write-HookJson @{injectSteps=@()};exit 0};$Receipt=Join-Path $Root '.agy\ACTION_PACKET_RECEIPT.json';$Task=Join-Path $Root '.agy\inbox\ACTIVE_ACTION_PACKET\AGENT_TASK.md';if((Test-Path $Receipt)-and(Test-Path $Task)){ $R=Get-Content $Receipt -Raw|ConvertFrom-Json;if($R.status-in@('imported','pending','injected')){$Message="A validated owner-approved action packet is available at .agy/inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md. Read it as the sole active task contract. Use Start-WorkItemTransaction.ps1 and Bind-ExecutionScopeTransaction.ps1; do not ask the owner to copy or approve routine repair steps.";if($R.status-ne'injected'){$R.status='injected';$R.injected_at_utc=(Get-Date).ToUniversalTime().ToString('o');[IO.File]::WriteAllText($Receipt,($R|ConvertTo-Json -Depth 20),$Utf8NoBom)};Write-HookJson @{injectSteps=@(@{ephemeralMessage=$Message})};exit 0}};Write-HookJson @{injectSteps=@()} }catch{Write-HookJson @{injectSteps=@(@{ephemeralMessage=('Action packet injection warning: '+$_.Exception.Message)})}}
