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
  $HookPayload=Read-HookInput;$ToolArguments=$HookPayload.toolCall.args;$Target=[string]$ToolArguments.TargetFile;$Root=Resolve-ProjectRoot $HookPayload $Target
  if(-not $Root){Write-HookJson @{decision='deny';reason='Не удалось определить проект. Запись остановлена до точной привязки.'};exit 0}
  $Agy=Join-Path $Root '.agy';$Required=@('WORK_ITEM.json','EXECUTION_SCOPE.json','EXECUTION_LEASE.json','STAGE_FIREWALL.json')
  foreach($Name in $Required){if(!(Test-Path -LiteralPath (Join-Path $Agy $Name)-PathType Leaf)){Write-HookJson @{decision='deny';reason="Запись остановлена: отсутствует $Name. Сначала выполните атомарную привязку work item."};exit 0}}
  $Wi=Get-Content (Join-Path $Agy 'WORK_ITEM.json') -Raw|ConvertFrom-Json;$ScopeRaw=Get-Content (Join-Path $Agy 'EXECUTION_SCOPE.json') -Raw;$Scope=$ScopeRaw|ConvertFrom-Json;$Lease=Get-Content (Join-Path $Agy 'EXECUTION_LEASE.json') -Raw|ConvertFrom-Json;$Firewall=Get-Content (Join-Path $Agy 'STAGE_FIREWALL.json') -Raw|ConvertFrom-Json
  if($Wi.owner_approved-ne$true-or$Lease.status-ne'active'-or$Scope.status-ne'exact'){Write-HookJson @{decision='deny';reason='Запись остановлена: execution authority не активна.'};exit 0}
  if([string]$Wi.work_item_id-ne[string]$Lease.work_item_id-or[int]$Wi.goal_epoch-ne[int]$Lease.goal_epoch){Write-HookJson @{decision='deny';reason='Запись остановлена: work item и lease не совпадают.'};exit 0}
  $Rel=Normalize-Rel $Root $Target;$Allowed=$false;foreach($Pattern in @($Lease.allowed_paths)){if(Test-Pattern $Rel ([string]$Pattern)){$Allowed=$true;break}}
  if(-not$Allowed){Write-HookJson @{decision='deny';reason="Файл вне разрешённой области текущей задачи: $Rel"};exit 0}
  if($Firewall.status-ne'active'-or[string]$Firewall.work_item_id-ne[string]$Wi.work_item_id){Write-HookJson @{decision='deny';reason='Запись остановлена: stage firewall не активен для текущей задачи.'};exit 0}
  $Blocked=$false;foreach($Pattern in @($Firewall.protected_path_patterns)){if(Test-Pattern $Rel ([string]$Pattern)){$Blocked=$true;break}}
  if($Blocked-and$Firewall.algorithm_repair_authorized-ne$true){Write-HookJson @{decision='deny';reason="Scientific stage firewall запрещает изменение: $Rel"};exit 0}
  if($Lease.first_write_started-ne$true){$Lease.first_write_started=$true;$Lease.first_write_started_at_utc=(Get-Date).ToUniversalTime().ToString('o');$Tmp=(Join-Path $Agy 'EXECUTION_LEASE.json.tmp');[IO.File]::WriteAllText($Tmp,($Lease|ConvertTo-Json -Depth 30),$Utf8NoBom);Move-Item $Tmp (Join-Path $Agy 'EXECUTION_LEASE.json') -Force}
  Write-HookJson @{decision='allow';reason='Exact execution lease permits this file.'}
} catch { Write-HookJson @{decision='deny';reason=('Pre-write guard error: '+$_.Exception.Message)} }
