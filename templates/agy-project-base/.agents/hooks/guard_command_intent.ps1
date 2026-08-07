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

try {
  $HookPayload=Read-HookInput;$ToolArguments=$HookPayload.toolCall.args;$Command=[string]$ToolArguments.CommandLine;$Cwd=[string]$ToolArguments.Cwd;$Root=Resolve-ProjectRoot $HookPayload $Cwd
  if(-not$Root){Write-HookJson @{decision='deny';reason='Команда остановлена: проект не определён.'};exit 0}
  $ReadOnly='(?i)^\s*(git\s+(status|diff|rev-parse|log|show|branch|worktree\s+list)|Get-Content|Get-ChildItem|Test-Path|Select-String|node\s+--check|npm\s+(test|run\s+(test|typecheck|build))|npx\s+vitest|python\s+(-m\s+pytest|.*--version)|pwsh\s+.*Test-[^\s]+\.ps1)\b'
  $Control='(?i)(Start-WorkItemTransaction|Bind-ExecutionScopeTransaction|Import-ActionPacket|Validate-ControlPlaneState|Test-ExecutionLease|Test-FindingSet|Publish-AuditCoverageMatrix|Register-FindingDelta|Register-Progress|Publish-CandidateManifest)\.ps1'
  $Destructive='(?i)(git\s+(reset\s+--hard|clean\s+-|checkout\s+--|push\s+--force)|Remove-Item\s+.*-Recurse|rm\s+-rf|del\s+/[sq]|format\s+|diskpart|DROP\s+(TABLE|DATABASE))'
  if($Command-match$Destructive){Write-HookJson @{decision='force_ask';reason='Команда потенциально разрушительна и требует явного решения владельца.'};exit 0}
  if($Command-match$ReadOnly-or$Command-match$Control){Write-HookJson @{decision='allow';reason='Разрешённая read-only/control-plane команда.'};exit 0}
  $LeasePath=Join-Path $Root '.agy\EXECUTION_LEASE.json';if(!(Test-Path $LeasePath)){Write-HookJson @{decision='deny';reason='Команда может менять проект, но точный execution lease ещё не создан.'};exit 0}
  $Lease=Get-Content $LeasePath -Raw|ConvertFrom-Json;if($Lease.status-ne'active'){Write-HookJson @{decision='deny';reason='Execution lease не активен.'};exit 0}
  $Patterns=@($Lease.allowed_command_patterns);if($Patterns.Count-eq0){Write-HookJson @{decision='deny';reason='Команда не относится к read-only и не указана в allowed_command_patterns.'};exit 0}
  foreach($Pattern in $Patterns){if($Command-match[string]$Pattern){Write-HookJson @{decision='allow';reason='Команда разрешена точным lease.'};exit 0}}
  Write-HookJson @{decision='deny';reason='Команда не входит в точный command scope текущей задачи.'}
} catch { Write-HookJson @{decision='deny';reason=('Command guard error: '+$_.Exception.Message)} }
