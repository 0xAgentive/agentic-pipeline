[CmdletBinding()]
param([string]$RepoRoot = '.')

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $Root 'scripts\windows\common\NativeProcess.ps1')
$Compiler = Join-Path $Root 'scripts\windows\companion\Compile-ResultAuthority.ps1'
$TemplateCompiler = Join-Path $Root 'templates\agy-project-base\scripts\windows\companion\Compile-ResultAuthority.ps1'
$CandidatePublisher = Join-Path $Root 'scripts\windows\companion\Publish-CandidateManifest.ps1'
$TemplateCandidatePublisher = Join-Path $Root 'templates\agy-project-base\scripts\windows\companion\Publish-CandidateManifest.ps1'
$ReceiptSchema = Join-Path $Root 'schemas\companion\verification-receipt.schema.json'
$TemplateReceiptSchema = Join-Path $Root 'templates\agy-project-base\schemas\companion\verification-receipt.schema.json'
$RunResultSchema = Join-Path $Root 'schemas\companion\run-result.schema.json'
$WorkerSource = Join-Path $Root 'integrations\companion-handoff-1.2.26\source\src'
$CompanionControl = Join-Path $Root 'scripts\companion\companion-control.cjs'
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$Node = (Get-Command node -ErrorAction Stop).Source
$PythonCommand = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $PythonCommand) { $PythonCommand = Get-Command python3 -ErrorAction Stop | Select-Object -First 1 }
$Python = $PythonCommand.Source
$Utf8 = [Text.UTF8Encoding]::new($false)
$Assertions = 0
$CompilerHandles = [Collections.Generic.List[object]]::new()
$SourceStatusBefore = (& git -C $Root status --porcelain=v2 -z --untracked-files=all)

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
  $script:Assertions++
}

function Write-Json {
  param([string]$Path, $Value)
  $Parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 80), $Utf8)
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Set-FixtureCandidateTimes {
  param($Fixture, [string]$GeneratedAt, [string]$UpdatedAt)
  $CandidatePath = Join-Path $Fixture.Agy 'CANDIDATE_MANIFEST.json'
  $StatusPath = Join-Path $Fixture.Agy 'CANDIDATE_MANIFEST_STATUS.json'
  $Candidate = Get-Content -LiteralPath $CandidatePath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $Candidate.generated_at_utc = $GeneratedAt
  Write-Json $CandidatePath $Candidate
  $CandidateHash = Get-Sha256 $CandidatePath
  $Status = Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $Status.manifest_sha256 = $CandidateHash
  $Status.updated_at_utc = $UpdatedAt
  Write-Json $StatusPath $Status
  $Receipt = Get-Content -LiteralPath $Fixture.ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $Receipt.candidate_manifest_sha256 = $CandidateHash
  Write-Json $Fixture.ReceiptPath $Receipt
}

function Invoke-WorkerAuthorityValidator {
  param($Fixture)
  $Code = @'
import json
import sys
sys.path.insert(0, sys.argv[1])
from run_ag_handoff_worker import validate_authority_freshness
result = validate_authority_freshness(
    {"workspacePaths": [sys.argv[2]], "fullyIdle": True},
    sys.argv[3],
)
print(json.dumps(result, ensure_ascii=True, sort_keys=True))
raise SystemExit(0 if result.get("ready") else 2)
'@
  return Invoke-AgenticNativeProcess -FilePath $Python -ArgumentList @('-B','-c',$Code,$WorkerSource,$Fixture.Project,[DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o')) -WorkingDirectory $Fixture.Project
}

function Test-CandidatePublisherMultiRecord {
  $Project = Join-Path $script:TempRoot 'candidate-publisher-multi-record'
  $Source = Join-Path $Project 'src'
  New-Item -ItemType Directory -Force -Path $Source | Out-Null
  foreach ($Name in @('modified.txt','deleted.txt','rename-old.txt')) {
    [IO.File]::WriteAllText((Join-Path $Source $Name), "baseline-$Name`n", $Utf8)
  }
  Write-Json (Join-Path $Project '.agy/NEXT_ACTION.json') ([ordered]@{schema_version='1.1.0';work_item_id='work-candidate-publisher';route='/nextphase';auto_continue=$true;updated_at_utc=[DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')})
  & git -C $Project init --quiet --initial-branch=main
  & git -C $Project config user.name 'Candidate Publisher Regression'
  & git -C $Project config user.email 'candidate-publisher@local.invalid'
  & git -C $Project add --all
  & git -C $Project -c commit.gpgsign=false commit --quiet -m baseline
  if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize candidate-publisher fixture.' }

  [IO.File]::WriteAllText((Join-Path $Source 'modified.txt'), "modified`n", $Utf8)
  Remove-Item -LiteralPath (Join-Path $Source 'deleted.txt')
  & git -C $Project mv -- 'src/rename-old.txt' 'src/renamed.txt'
  if ($LASTEXITCODE -ne 0) { throw 'Unable to create candidate-publisher rename fixture.' }
  [IO.File]::WriteAllText((Join-Path $Source 'юникод name.txt'), "unicode`n", $Utf8)
  New-Item -ItemType Directory -Force -Path (Join-Path $Project 'outside') | Out-Null
  [IO.File]::WriteAllText((Join-Path $Project 'outside/ambient.txt'), "ambient`n", $Utf8)
  Write-Json (Join-Path $Project '.agy/EXECUTION_LEASE.json') ([ordered]@{
    schema_version='1.0.0';lease_id='lease-candidate-publisher';status='active';work_item_id='work-candidate-publisher';goal_epoch=1;branch='main';baseline_head=(& git -C $Project rev-parse HEAD).Trim();issued_at_utc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o');allowed_paths=@('src/**')
  })

  $Arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$CandidatePublisher,'-ProjectRoot',$Project)
  $Dry = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList $Arguments
  Assert-True ($Dry.ExitCode -eq 0) "Candidate publisher multi-record dry-run failed: $($Dry.StdErr)"
  $Plan = $Dry.StdOut | ConvertFrom-Json -DateKind String
  $ExpectedCandidate = @('src/deleted.txt','src/modified.txt','src/renamed.txt','src/юникод name.txt')
  $ActualCandidate = @($Plan.manifest.candidate_files | ForEach-Object { [string]$_.path })
  $ActualAmbient = @($Plan.manifest.ambient_git_status | ForEach-Object { [string]$_.path })
  Assert-True ([int]$Plan.status.candidate_file_count -eq 4 -and $ActualCandidate.Count -eq 4) 'Candidate publisher collapsed multiple leased Git records.'
  Assert-True ([int]$Plan.status.ambient_file_count -eq 2 -and $ActualAmbient.Count -eq 2) 'Candidate publisher collapsed or omitted ambient Git records.'
  Assert-True (@(Compare-Object $ExpectedCandidate $ActualCandidate -CaseSensitive).Count -eq 0) "Candidate publisher emitted the wrong leased path set: $($ActualCandidate -join ', ')"
  Assert-True (@(Compare-Object @('.agy/EXECUTION_LEASE.json','outside/ambient.txt') $ActualAmbient -CaseSensitive).Count -eq 0) "Candidate publisher emitted the wrong ambient path set: $($ActualAmbient -join ', ')"
  Assert-True (@($Plan.manifest.control_plane_files | Where-Object { [string]$_.path -ceq '.agy/NEXT_ACTION.json' }).Count -eq 0) 'Candidate publisher bound compiler-owned NEXT_ACTION as an immutable payload authority input.'

  $ReceiptSentinelPath = Join-Path $Project '.agy/VERIFICATION_RECEIPT.json'
  Write-Json $ReceiptSentinelPath ([ordered]@{schema_version='1.0.0';candidate_manifest_sha256=('0' * 64);changed_files=@('sentinel.txt');completed_at_utc='2026-08-11T00:00:00.0000000Z'})
  $ReceiptSentinelBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ReceiptSentinelPath))
  $ReceiptSentinelMtime = (Get-Item -LiteralPath $ReceiptSentinelPath).LastWriteTimeUtc.Ticks
  $Apply = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList ($Arguments + '-Apply')
  Assert-True ($Apply.ExitCode -eq 0) "Candidate publisher multi-record apply failed: $($Apply.StdErr)"
  $Published = Get-Content -LiteralPath (Join-Path $Project '.agy/CANDIDATE_MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $PublishedStatus = Get-Content -LiteralPath (Join-Path $Project '.agy/CANDIDATE_MANIFEST_STATUS.json') -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  Assert-True (@($Published.candidate_files).Count -eq 4 -and [int]$PublishedStatus.candidate_file_count -eq 4) 'Published candidate manifest lost multi-record Git state.'
  Assert-True ([string]$PublishedStatus.manifest_sha256 -ceq (Get-Sha256 (Join-Path $Project '.agy/CANDIDATE_MANIFEST.json'))) 'Published candidate status is not bound to exact manifest bytes.'
  Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ReceiptSentinelPath)) -ceq $ReceiptSentinelBytes -and (Get-Item -LiteralPath $ReceiptSentinelPath).LastWriteTimeUtc.Ticks -eq $ReceiptSentinelMtime) 'Candidate publisher mutated or rebound an existing verification receipt.'
}

function Invoke-Compiler {
  param(
    [string]$Project,
    [string]$Receipt,
    [switch]$Apply,
    [int]$TimeoutSeconds = 15,
    [int]$FaultAfter = 0
  )
  $Arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Compiler,'-ProjectRoot',$Project,'-VerificationReceiptPath',$Receipt,'-TimeoutSeconds',[string]$TimeoutSeconds)
  if ($Apply) { $Arguments += '-Apply' }
  if ($FaultAfter -gt 0) { $Arguments += @('-FaultInjectionAfterPublishes',[string]$FaultAfter) }
  return Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList $Arguments
}

function Start-Compiler {
  param([string]$Project, [string]$Receipt, [switch]$Apply, [int]$TimeoutSeconds = 15)
  $Info = [Diagnostics.ProcessStartInfo]::new()
  $Info.FileName = $Pwsh
  $Info.WorkingDirectory = $Project
  $Info.UseShellExecute = $false
  $Info.CreateNoWindow = $true
  $Info.RedirectStandardInput = $true
  $Info.RedirectStandardOutput = $true
  $Info.RedirectStandardError = $true
  $Info.StandardOutputEncoding = $Utf8
  $Info.StandardErrorEncoding = $Utf8
  foreach ($Argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Compiler,'-ProjectRoot',$Project,'-VerificationReceiptPath',$Receipt,'-TimeoutSeconds',[string]$TimeoutSeconds)) { [void]$Info.ArgumentList.Add($Argument) }
  if ($Apply) { [void]$Info.ArgumentList.Add('-Apply') }
  $Process = [Diagnostics.Process]::new()
  $Process.StartInfo = $Info
  if (-not $Process.Start()) { throw 'Failed to start compiler regression process.' }
  $Process.StandardInput.Close()
  $Handle = [pscustomobject]@{ Process=$Process; StdOut=$Process.StandardOutput.ReadToEndAsync(); StdErr=$Process.StandardError.ReadToEndAsync() }
  [void]$script:CompilerHandles.Add($Handle)
  return $Handle
}

function Complete-Compiler {
  param($Handle, [int]$TimeoutSeconds = 30)
  if (-not $Handle.Process.WaitForExit($TimeoutSeconds * 1000)) {
    try { $Handle.Process.Kill($true) } catch {}
    throw "Compiler regression process $($Handle.Process.Id) exceeded $TimeoutSeconds seconds."
  }
  $Handle.Process.WaitForExit()
  $Result = [pscustomobject]@{ ExitCode=$Handle.Process.ExitCode; StdOut=$Handle.StdOut.GetAwaiter().GetResult(); StdErr=$Handle.StdErr.GetAwaiter().GetResult() }
  $Handle.Process.Dispose()
  [void]$script:CompilerHandles.Remove($Handle)
  return $Result
}

function Wait-ForFile {
  param([string]$Path, [int]$TimeoutSeconds = 10)
  $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTimeOffset]::UtcNow -lt $Deadline) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
    Start-Sleep -Milliseconds 50
  }
  throw "Timed out waiting for fixture evidence: $Path"
}

function Wait-ForProcessExit {
  param([int]$TargetProcessId, [int]$TimeoutSeconds = 5)
  $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTimeOffset]::UtcNow -lt $Deadline) {
    if ($null -eq (Get-Process -Id $TargetProcessId -ErrorAction SilentlyContinue)) { return }
    Start-Sleep -Milliseconds 50
  }
  throw "Timed out waiting for fixture process $TargetProcessId to exit."
}

function Write-Validator {
  param([string]$Project, [ValidateSet('quick','slow','barrier','child')][string]$Mode, [int]$DelayMilliseconds = 1800)
  $Path = Join-Path $Project 'scripts\windows\companion\Test-FindingSet.ps1'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $Body = switch ($Mode) {
    'quick' { "[CmdletBinding()]param([string]`$ProjectRoot='.',[string]`$FindingSetPath='')`r`nexit 0`r`n" }
    'slow' { @'
[CmdletBinding()]param([string]$ProjectRoot='.',[string]$FindingSetPath='')
$runtime=Join-Path $ProjectRoot '.agy/.runtime/result-authority'
New-Item -ItemType Directory -Force -Path $runtime|Out-Null
Add-Content -LiteralPath (Join-Path $runtime 'validator-count.txt') -Value 'run' -Encoding utf8
Start-Sleep -Milliseconds __DELAY__
exit 0
'@ }
    'barrier' { @'
[CmdletBinding()]param([string]$ProjectRoot='.',[string]$FindingSetPath='')
$runtime=Join-Path $ProjectRoot '.agy/.runtime/result-authority'
New-Item -ItemType Directory -Force -Path $runtime|Out-Null
Add-Content -LiteralPath (Join-Path $runtime 'validator-count.txt') -Value 'run' -Encoding utf8
$release=Join-Path $runtime 'validator-release.txt'
$deadline=[DateTimeOffset]::UtcNow.AddSeconds(30)
while(-not(Test-Path -LiteralPath $release -PathType Leaf)){
  if([DateTimeOffset]::UtcNow-ge$deadline){throw 'Timed out waiting for validator release barrier.'}
  Start-Sleep -Milliseconds 50
}
exit 0
'@ }
    'child' { @'
[CmdletBinding()]param([string]$ProjectRoot='.',[string]$FindingSetPath='')
$runtime=Join-Path $ProjectRoot '.agy/.runtime/result-authority'
New-Item -ItemType Directory -Force -Path $runtime|Out-Null
Start-Sleep -Milliseconds __DELAY__
$pwsh=(Get-Command pwsh -ErrorAction Stop).Source
$start=@{FilePath=$pwsh;ArgumentList=@('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30');PassThru=$true}
if($IsWindows){$start.WindowStyle='Hidden'}
$child=Start-Process @start
$childPidPath=Join-Path $runtime 'child.pid'
$childPidTemporary="$childPidPath.$PID.tmp"
[IO.File]::WriteAllText($childPidTemporary,[string]$child.Id,[Text.UTF8Encoding]::new($false))
[IO.File]::Move($childPidTemporary,$childPidPath,$true)
$child.WaitForExit()
exit 0
'@ }
  }
  $Body = $Body.Replace('__DELAY__', [string]$DelayMilliseconds)
  [IO.File]::WriteAllText($Path, $Body, $Utf8)
}

function New-Fixture {
  param([string]$Name, [ValidateSet('none','quick','slow','barrier','child')][string]$Validator = 'none', [int]$SlowMilliseconds = 1800, [switch]$BindExistingNextAction)
  $Project = Join-Path $script:TempRoot $Name
  New-Item -ItemType Directory -Force -Path (Join-Path $Project 'src') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Project '.agy\verification') | Out-Null
  $CandidateRelative = 'src/result authority юникод.txt'
  $CandidatePath = Join-Path $Project $CandidateRelative
  [IO.File]::WriteAllText($CandidatePath, "baseline`n", $Utf8)
  & git -C $Project init --quiet --initial-branch=main
  & git -C $Project config user.name 'Result Authority Regression'
  & git -C $Project config user.email 'result-authority@local.invalid'
  & git -C $Project add --all
  & git -C $Project -c commit.gpgsign=false commit --quiet -m baseline
  if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize result-authority fixture.' }
  $Head = (& git -C $Project rev-parse HEAD).Trim()
  $Branch = (& git -C $Project branch --show-current).Trim()
  [IO.File]::WriteAllText($CandidatePath, "verified candidate`n", $Utf8)
  $CandidateItem = Get-Item -LiteralPath $CandidatePath
  $CandidateItem.LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5)
  $Agy = Join-Path $Project '.agy'
  $Issued = [DateTimeOffset]::UtcNow.AddMinutes(-4)
  $WorkItem = [ordered]@{schema_version='1.0.0';work_item_id="work-$Name";goal_epoch=1;goal='Compile an exact result';assurance_mode='flow';status='active';owner_approved=$true;created_at_utc=$Issued.ToString('o');updated_at_utc=$Issued.ToString('o')}
  $Lease = [ordered]@{schema_version='1.0.0';lease_id="lease-$Name";status='active';work_item_id=$WorkItem.work_item_id;goal_epoch=1;branch=$Branch;baseline_head=$Head;allowed_paths=@('src/**');issued_at_utc=$Issued.ToString('o')}
  Write-Json (Join-Path $Agy 'WORK_ITEM.json') $WorkItem
  Write-Json (Join-Path $Agy 'EXECUTION_LEASE.json') $Lease
  $Progress = [ordered]@{schema_version='1.1.0';work_item_id=$WorkItem.work_item_id;status='progressing';observations_count=1;consecutive_no_progress=0;same_failure_count=0;owner_decision_required=$false;updated_at_utc=$Issued.ToString('o');history=@()}
  Write-Json (Join-Path $Agy 'PROGRESS_STATE.json') $Progress
  if ($BindExistingNextAction) {
    Write-Json (Join-Path $Agy 'NEXT_ACTION.json') ([ordered]@{schema_version='1.1.0';work_item_id=$WorkItem.work_item_id;route='/nextphase';auto_continue=$true;owner_decision_required=$false;owner_decision_reason=$null;technical_task_path=$null;updated_at_utc=$Issued.ToString('o')})
  }
  if ($Validator -ne 'none') {
    Write-Validator $Project $Validator $SlowMilliseconds
    Write-Json (Join-Path $Agy 'FINDINGS.json') ([ordered]@{schema_version='1.0.0';work_item_id=$WorkItem.work_item_id;findings=@();updated_at_utc=$Issued.ToString('o')})
  }
  $EvidencePath = Join-Path $Agy 'verification\required-test.log'
  [IO.File]::WriteAllText($EvidencePath, "required test passed`n", $Utf8)
  (Get-Item -LiteralPath $EvidencePath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-3)
  $DirtyName = if ($IsWindows) { 'untracked юникод name.txt' } else { "untracked`nюникод.txt" }
  [IO.File]::WriteAllText((Join-Path $Project $DirtyName), 'porcelain-v2-z regression', $Utf8)
  $Fixture = [pscustomobject]@{Project=$Project;Agy=$Agy;Head=$Head;Branch=$Branch;WorkItem=$WorkItem;Lease=$Lease;Progress=$Progress;CandidateRelative=$CandidateRelative;CandidatePath=$CandidatePath;EvidencePath=$EvidencePath;ReceiptPath=(Join-Path $Agy 'receipt-input.json');Validator=$Validator;Revision=0;BindExistingNextAction=[bool]$BindExistingNextAction}
  [void](Update-FixtureAuthority $Fixture)
  return $Fixture
}

function Update-FixtureAuthority {
  param($Fixture)
  $Fixture.Revision++
  $Now = [DateTimeOffset]::UtcNow
  $CandidateTime = $Now.AddMinutes(-4)
  $StatusTime = $Now.AddMinutes(-3).AddSeconds(-30)
  $ReceiptTime = $Now.AddSeconds(-1)
  $Fixture.Progress.observations_count = $Fixture.Revision
  $Fixture.Progress.updated_at_utc = $CandidateTime.ToString('o')
  Write-Json (Join-Path $Fixture.Agy 'PROGRESS_STATE.json') $Fixture.Progress
  $ControlNames = @('WORK_ITEM.json','EXECUTION_LEASE.json','PROGRESS_STATE.json')
  if ($Fixture.Validator -ne 'none') { $ControlNames += 'FINDINGS.json' }
  if ($Fixture.BindExistingNextAction) { $ControlNames += 'NEXT_ACTION.json' }
  $Controls = @($ControlNames | ForEach-Object {
    $Path = Join-Path $Fixture.Agy $_
    [ordered]@{path=".agy/$_";size_bytes=[long](Get-Item -LiteralPath $Path).Length;sha256=Get-Sha256 $Path}
  })
  $DirtyName = if ($IsWindows) { 'untracked юникод name.txt' } else { "untracked`nюникод.txt" }
  $AmbientEntries = @([ordered]@{status='??';path=$DirtyName})
  if ($Fixture.Validator -ne 'none') {
    $AmbientEntries += [ordered]@{status='??';path='scripts/windows/companion/Test-FindingSet.ps1'}
  }
  $Candidate = [ordered]@{
    schema_version='1.1.0';work_item_id=$Fixture.WorkItem.work_item_id;lease_id=$Fixture.Lease.lease_id;branch=$Fixture.Branch;head=$Fixture.Head;generated_at_utc=$CandidateTime.ToString('o')
    candidate_files=@([ordered]@{path=$Fixture.CandidateRelative;exists=$true;size_bytes=[long](Get-Item -LiteralPath $Fixture.CandidatePath).Length;sha256=Get-Sha256 $Fixture.CandidatePath})
    control_plane_files=$Controls
    ambient_git_status=$AmbientEntries
  }
  $CandidatePath = Join-Path $Fixture.Agy 'CANDIDATE_MANIFEST.json'
  Write-Json $CandidatePath $Candidate
  $CandidateHash = Get-Sha256 $CandidatePath
  Write-Json (Join-Path $Fixture.Agy 'CANDIDATE_MANIFEST_STATUS.json') ([ordered]@{schema_version='1.1.0';status='current';manifest_path='.agy/CANDIDATE_MANIFEST.json';manifest_sha256=$CandidateHash;updated_at_utc=$StatusTime.ToString('o')})
  $Evidence = Get-Item -LiteralPath $Fixture.EvidencePath
  $Receipt = [ordered]@{
    schema_version='1.0.0';work_item_id=$Fixture.WorkItem.work_item_id;goal_epoch=1;branch=$Fixture.Branch;head=$Fixture.Head;execution_lease_id=$Fixture.Lease.lease_id;candidate_manifest_sha256=$CandidateHash;completed_at_utc=$ReceiptTime.ToString('o')
    changed_files=@($Fixture.CandidateRelative)
    tests=@([ordered]@{run_id="required-$($Fixture.Revision)";required=$true;exit_code=0;started_at_utc=$Now.AddMinutes(-3).ToString('o');completed_at_utc=$Now.AddMinutes(-2).ToString('o');evidence_path='.agy/verification/required-test.log';evidence_sha256=Get-Sha256 $Fixture.EvidencePath;evidence_size_bytes=[long]$Evidence.Length;summary='passed'})
    evidence_artifacts=@('.agy/verification/required-test.log');product_artifacts=@()
  }
  Write-Json $Fixture.ReceiptPath $Receipt
  return $Receipt
}

function Assert-NoCompilerWrites {
  param($Fixture)
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $Fixture.Agy '.runtime\result-authority') -PathType Container)) 'Fail-before-write validation created result-authority runtime state.'
  foreach ($Name in @('VERIFICATION_RECEIPT.json','CLOSURE_STATE.json','RUN_RESULT.json','NEXT_ACTION.json')) { Assert-True (-not (Test-Path -LiteralPath (Join-Path $Fixture.Agy $Name))) "Fail-before-write validation created $Name." }
}

function Get-OutputSnapshot {
  param($Fixture)
  $Rows = @()
  foreach ($Name in @('VERIFICATION_RECEIPT.json','CLOSURE_STATE.json','RUN_RESULT.json','NEXT_ACTION.json')) {
    $Path = Join-Path $Fixture.Agy $Name
    $Item = Get-Item -LiteralPath $Path
    $Rows += "$Name`0$($Item.Length)`0$(Get-Sha256 $Path)`0$($Item.LastWriteTimeUtc.Ticks)"
  }
  return $Rows
}

$TempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$TempRoot = [IO.Path]::GetFullPath((Join-Path $TempBase ('agentic-result-authority-' + [Guid]::NewGuid().ToString('N'))))
if (-not $TempRoot.StartsWith($TempBase, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $TempRoot) -cnotmatch '^agentic-result-authority-[0-9a-f]{32}$') { throw "Unsafe temporary root: $TempRoot" }

try {
  New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
  Assert-True ((Get-Sha256 $Compiler) -eq (Get-Sha256 $TemplateCompiler)) 'Canonical and template compiler bytes differ.'
  Assert-True ((Get-Sha256 $CandidatePublisher) -eq (Get-Sha256 $TemplateCandidatePublisher)) 'Canonical and template candidate publisher bytes differ.'
  Assert-True ((Get-Sha256 $ReceiptSchema) -eq (Get-Sha256 $TemplateReceiptSchema)) 'Canonical and template receipt schema bytes differ.'
  Test-CandidatePublisherMultiRecord

  $NoArgument = New-Fixture 'no-argument'
  $NoArgumentResult = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile','-NonInteractive','-Command',"& '$($Compiler.Replace("'","''"))'") -WorkingDirectory $NoArgument.Project
  Assert-True ($NoArgumentResult.ExitCode -ne 0 -and ($NoArgumentResult.StdErr + $NoArgumentResult.StdOut) -match 'RESULT_AUTHORITY_VERIFICATION_RECEIPT_REQUIRED') 'Missing receipt did not fail fast with a machine-readable error.'
  Assert-NoCompilerWrites $NoArgument

  $Stale = New-Fixture 'stale-receipt'
  $StaleReceipt = Get-Content -LiteralPath $Stale.ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $StaleReceipt.PSObject.Properties.Remove('schema_version')
  Write-Json $Stale.ReceiptPath $StaleReceipt
  $StaleResult = Invoke-Compiler $Stale.Project $Stale.ReceiptPath -Apply
  Assert-True ($StaleResult.ExitCode -ne 0 -and ($StaleResult.StdErr + $StaleResult.StdOut) -match 'RESULT_AUTHORITY_RECEIPT_SCHEMA') 'PRE_REPAIR-style receipt was not rejected before writes.'
  Assert-NoCompilerWrites $Stale

  $Escape = New-Fixture 'path-escape'
  $EscapeReceipt = Get-Content -LiteralPath $Escape.ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $EscapeReceipt.changed_files = @('../escape.txt')
  Write-Json $Escape.ReceiptPath $EscapeReceipt
  $EscapeResult = Invoke-Compiler $Escape.Project $Escape.ReceiptPath
  Assert-True ($EscapeResult.ExitCode -ne 0 -and ($EscapeResult.StdErr + $EscapeResult.StdOut) -match 'RESULT_AUTHORITY_RECEIPT_BINDING') 'Parent-segment receipt path was accepted.'
  Assert-NoCompilerWrites $Escape

  $ReconFixture = New-Fixture 'recon-marker-block'
  [IO.File]::WriteAllText((Join-Path $ReconFixture.Agy 'HOOK_RECONCILIATION_REQUIRED.json'), '{"schema_version":"1.0.0"}', $Utf8)
  $ReconRejected = Invoke-Compiler $ReconFixture.Project $ReconFixture.ReceiptPath -Apply
  Assert-True ($ReconRejected.ExitCode -ne 0 -and ($ReconRejected.StdErr + $ReconRejected.StdOut) -match 'RESULT_AUTHORITY_RECONCILIATION_REQUIRED') 'Reconciliation marker was not rejected before writes.'
  Assert-NoCompilerWrites $ReconFixture

  $ReconStatusFixture = New-Fixture 'recon-status-block'
  $StatusObj = Get-Content -LiteralPath (Join-Path $ReconStatusFixture.Agy 'CANDIDATE_MANIFEST_STATUS.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $StatusObj.status = 'reconciliation_required'
  Write-Json (Join-Path $ReconStatusFixture.Agy 'CANDIDATE_MANIFEST_STATUS.json') $StatusObj
  $ReconStatusRejected = Invoke-Compiler $ReconStatusFixture.Project $ReconStatusFixture.ReceiptPath -Apply
  Assert-True ($ReconStatusRejected.ExitCode -ne 0 -and ($ReconStatusRejected.StdErr + $ReconStatusRejected.StdOut) -match 'RESULT_AUTHORITY_RECONCILIATION_REQUIRED') 'Reconciliation status was not rejected before writes.'
  Assert-NoCompilerWrites $ReconStatusFixture

  $IncompleteCandidate = New-Fixture 'candidate-incomplete'
  [IO.File]::WriteAllText((Join-Path $IncompleteCandidate.Project 'src/untracked-leased.txt'), 'untracked leased content', $Utf8)
  $IncompleteRejected = Invoke-Compiler $IncompleteCandidate.Project $IncompleteCandidate.ReceiptPath -Apply
  Assert-True ($IncompleteRejected.ExitCode -ne 0 -and ($IncompleteRejected.StdErr + $IncompleteRejected.StdOut) -match 'RESULT_AUTHORITY_CANDIDATE_INCOMPLETE') 'Omitted leased file in Git status was not rejected by candidate completeness check.'
  Assert-NoCompilerWrites $IncompleteCandidate

  foreach ($EvidenceCase in @(
    [pscustomobject]@{Name='outside-evidence';Path='outside-test.log';Expected='RESULT_AUTHORITY_TEST_EVIDENCE'},
    [pscustomobject]@{Name='sensitive-evidence';Path='.agy/verification/access-token.log';Expected='RESULT_AUTHORITY_TEST_EVIDENCE'}
  )) {
    $Fixture = New-Fixture $EvidenceCase.Name
    $OutsidePath = Join-Path $Fixture.Project $EvidenceCase.Path
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutsidePath) | Out-Null
    [IO.File]::WriteAllText($OutsidePath, 'forbidden evidence', $Utf8)
    (Get-Item $OutsidePath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-3)
    $Receipt = Get-Content -LiteralPath $Fixture.ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
    $Receipt.tests[0].evidence_path = $EvidenceCase.Path.Replace('\','/')
    $Receipt.tests[0].evidence_sha256 = Get-Sha256 $OutsidePath
    $Receipt.tests[0].evidence_size_bytes = [long](Get-Item $OutsidePath).Length
    Write-Json $Fixture.ReceiptPath $Receipt
    $Rejected = Invoke-Compiler $Fixture.Project $Fixture.ReceiptPath
    Assert-True ($Rejected.ExitCode -ne 0 -and ($Rejected.StdErr + $Rejected.StdOut) -match $EvidenceCase.Expected) "Forbidden evidence case was accepted: $($EvidenceCase.Name)"
    Assert-NoCompilerWrites $Fixture
  }

  $CandidateTamper = New-Fixture 'candidate-tamper'
  [IO.File]::AppendAllText($CandidateTamper.CandidatePath, 'tampered', $Utf8)
  $CandidateRejected = Invoke-Compiler $CandidateTamper.Project $CandidateTamper.ReceiptPath -Apply
  Assert-True ($CandidateRejected.ExitCode -ne 0 -and ($CandidateRejected.StdErr + $CandidateRejected.StdOut) -match 'RESULT_AUTHORITY_CANDIDATE_BINDING') 'Mutated candidate bytes were not rejected before writes.'
  Assert-NoCompilerWrites $CandidateTamper

  $EvidenceTamper = New-Fixture 'evidence-tamper'
  [IO.File]::AppendAllText($EvidenceTamper.EvidencePath, 'tampered', $Utf8)
  $EvidenceRejected = Invoke-Compiler $EvidenceTamper.Project $EvidenceTamper.ReceiptPath -Apply
  Assert-True ($EvidenceRejected.ExitCode -ne 0 -and ($EvidenceRejected.StdErr + $EvidenceRejected.StdOut) -match 'RESULT_AUTHORITY_TEST_EVIDENCE') 'Mutated test evidence was not rejected before writes.'
  Assert-NoCompilerWrites $EvidenceTamper

  $LocalizedTimestamp = New-Fixture 'localized-candidate-timestamp'
  $LocalizedStatus = Get-Content -LiteralPath (Join-Path $LocalizedTimestamp.Agy 'CANDIDATE_MANIFEST_STATUS.json') -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  Set-FixtureCandidateTimes $LocalizedTimestamp '08/11/2026 03:38:33' ([string]$LocalizedStatus.updated_at_utc)
  $LocalizedRejected = Invoke-Compiler $LocalizedTimestamp.Project $LocalizedTimestamp.ReceiptPath -Apply
  Assert-True ($LocalizedRejected.ExitCode -ne 0 -and ($LocalizedRejected.StdErr + $LocalizedRejected.StdOut) -match 'RESULT_AUTHORITY_CANDIDATE_BINDING') 'Localized candidate timestamp was accepted as UTC authority.'
  Assert-NoCompilerWrites $LocalizedTimestamp

  $BeforeTestCandidate = New-Fixture 'candidate-one-tick-before-required-test-start'
  $BeforeTestReceipt = Get-Content -LiteralPath $BeforeTestCandidate.ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $BeforeRequiredStarted = [DateTimeOffset]::Parse([string]$BeforeTestReceipt.tests[0].started_at_utc, [Globalization.CultureInfo]::InvariantCulture)
  $OneTickBefore = $BeforeRequiredStarted.AddTicks(-1).ToString('o')
  Set-FixtureCandidateTimes $BeforeTestCandidate $OneTickBefore $OneTickBefore
  $BeforeTestAccepted = Invoke-Compiler $BeforeTestCandidate.Project $BeforeTestCandidate.ReceiptPath -Apply
  Assert-True ($BeforeTestAccepted.ExitCode -eq 0) "Candidate published one 100ns tick before a required test started was rejected: $($BeforeTestAccepted.StdErr)"
  $BeforeWorkerValidation = Invoke-WorkerAuthorityValidator $BeforeTestCandidate
  Assert-True ($BeforeWorkerValidation.ExitCode -eq 0 -and (($BeforeWorkerValidation.StdOut | ConvertFrom-Json).ready -eq $true)) "Compiler/worker roundtrip lost the accepted one-tick causal boundary: stdout=$($BeforeWorkerValidation.StdOut) stderr=$($BeforeWorkerValidation.StdErr)"

  $PostTestCandidate = New-Fixture 'candidate-one-tick-after-required-test-start'
  $PostTestReceipt = Get-Content -LiteralPath $PostTestCandidate.ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $RequiredStarted = [DateTimeOffset]::Parse([string]$PostTestReceipt.tests[0].started_at_utc, [Globalization.CultureInfo]::InvariantCulture)
  $OneTickAfter = $RequiredStarted.AddTicks(1).ToString('o')
  Set-FixtureCandidateTimes $PostTestCandidate $OneTickAfter $OneTickAfter
  $PostTestRejected = Invoke-Compiler $PostTestCandidate.Project $PostTestCandidate.ReceiptPath -Apply
  Assert-True ($PostTestRejected.ExitCode -ne 0 -and ($PostTestRejected.StdErr + $PostTestRejected.StdOut) -match 'RESULT_AUTHORITY_CANDIDATE_TEST_ORDER') 'Candidate published one 100ns tick after a required test started was accepted.'
  Assert-NoCompilerWrites $PostTestCandidate

  $MissingStart = New-Fixture 'required-test-start-missing'
  $MissingStartReceipt = Get-Content -LiteralPath $MissingStart.ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $MissingStartReceipt.tests[0].PSObject.Properties.Remove('started_at_utc')
  Write-Json $MissingStart.ReceiptPath $MissingStartReceipt
  $MissingStartSchema = Invoke-AgenticNativeProcess -FilePath $Node -ArgumentList @($CompanionControl,'validate-json','--schema',$ReceiptSchema,'--file',$MissingStart.ReceiptPath)
  Assert-True ($MissingStartSchema.ExitCode -ne 0) 'Receipt schema accepted a required test without started_at_utc.'
  $MissingStartRejected = Invoke-Compiler $MissingStart.Project $MissingStart.ReceiptPath -Apply
  Assert-True ($MissingStartRejected.ExitCode -ne 0 -and ($MissingStartRejected.StdErr + $MissingStartRejected.StdOut) -match 'RESULT_AUTHORITY_TEST_BINDING') 'Compiler accepted a required test without started_at_utc.'
  Assert-NoCompilerWrites $MissingStart
  $OptionalReceiptPath = Join-Path $MissingStart.Agy 'optional-test-receipt.json'
  $MissingStartReceipt.tests[0].required = $false
  Write-Json $OptionalReceiptPath $MissingStartReceipt
  $OptionalSchema = Invoke-AgenticNativeProcess -FilePath $Node -ArgumentList @($CompanionControl,'validate-json','--schema',$ReceiptSchema,'--file',$OptionalReceiptPath)
  Assert-True ($OptionalSchema.ExitCode -eq 0) "Receipt schema rejected an optional test without started_at_utc: $($OptionalSchema.StdErr)"

  $LocalizedReceiptPath = Join-Path $MissingStart.Agy 'localized-timestamp-receipt.json'
  $LocalizedReceipt = Get-Content -LiteralPath $OptionalReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $LocalizedReceipt.completed_at_utc = '08/11/2026 03:38:33'
  Write-Json $LocalizedReceiptPath $LocalizedReceipt
  $LocalizedReceiptSchema = Invoke-AgenticNativeProcess -FilePath $Node -ArgumentList @($CompanionControl,'validate-json','--schema',$ReceiptSchema,'--file',$LocalizedReceiptPath)
  Assert-True ($LocalizedReceiptSchema.ExitCode -ne 0) 'Receipt schema accepted a localized authority timestamp.'

  $ZonelessReceiptPath = Join-Path $MissingStart.Agy 'zoneless-timestamp-receipt.json'
  $ZonelessReceipt = Get-Content -LiteralPath $OptionalReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $ZonelessReceipt.tests[0].completed_at_utc = '2026-08-11T03:38:33.0000000'
  Write-Json $ZonelessReceiptPath $ZonelessReceipt
  $ZonelessReceiptSchema = Invoke-AgenticNativeProcess -FilePath $Node -ArgumentList @($CompanionControl,'validate-json','--schema',$ReceiptSchema,'--file',$ZonelessReceiptPath)
  Assert-True ($ZonelessReceiptSchema.ExitCode -ne 0) 'Receipt schema accepted a zoneless authority timestamp.'

  $Valid = New-Fixture 'valid-transaction'
  $SchemaValid = Invoke-AgenticNativeProcess -FilePath $Node -ArgumentList @($CompanionControl,'validate-json','--schema',$ReceiptSchema,'--file',$Valid.ReceiptPath)
  Assert-True ($SchemaValid.ExitCode -eq 0) "Valid verification receipt failed schema validation: $($SchemaValid.StdErr)"
  $InvalidSchemaPath = Join-Path $Valid.Agy 'invalid-schema-receipt.json'
  $InvalidSchema = Get-Content -LiteralPath $Valid.ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $InvalidSchema.tests[0].PSObject.Properties.Remove('evidence_sha256')
  Write-Json $InvalidSchemaPath $InvalidSchema
  $SchemaInvalid = Invoke-AgenticNativeProcess -FilePath $Node -ArgumentList @($CompanionControl,'validate-json','--schema',$ReceiptSchema,'--file',$InvalidSchemaPath)
  Assert-True ($SchemaInvalid.ExitCode -ne 0) 'Invalid verification receipt passed schema validation.'
  $InputReceiptBytes = [IO.File]::ReadAllBytes($Valid.ReceiptPath)
  $Dry = Invoke-Compiler $Valid.Project $Valid.ReceiptPath
  Assert-True ($Dry.ExitCode -eq 0 -and $Dry.StdOut -match 'verification_receipt') "Valid compiler dry-run failed: $($Dry.StdErr)"
  $Apply = Invoke-Compiler $Valid.Project $Valid.ReceiptPath -Apply
  Assert-True ($Apply.ExitCode -eq 0) "Valid compiler apply failed: $($Apply.StdErr)"
  Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $Valid.Agy 'VERIFICATION_RECEIPT.json'))) -ceq [Convert]::ToBase64String($InputReceiptBytes)) 'Canonical verification receipt is not byte-identical to the validated source receipt.'
  $Run = Get-Content -LiteralPath (Join-Path $Valid.Agy 'RUN_RESULT.json') -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  Assert-True ([string]$Run.verification_receipt.path -ceq '.agy/VERIFICATION_RECEIPT.json' -and [string]$Run.verification_receipt.sha256 -ceq (Get-Sha256 $Valid.ReceiptPath) -and [string]$Run.verification_receipt.work_item_id -ceq [string]$Valid.WorkItem.work_item_id -and [string]$Run.verification_receipt.head -ceq $Valid.Head) 'RUN_RESULT receipt provenance is incomplete or unbound.'
  $RunSchemaValid = Invoke-AgenticNativeProcess -FilePath $Node -ArgumentList @($CompanionControl,'validate-json','--schema',$RunResultSchema,'--file',(Join-Path $Valid.Agy 'RUN_RESULT.json'))
  Assert-True ($RunSchemaValid.ExitCode -eq 0) "Compiler RUN_RESULT failed schema validation: $($RunSchemaValid.StdErr)"
  $LocalizedRunPath = Join-Path $TempRoot 'localized-timestamp-run-result.json'
  $LocalizedRun = $Run | ConvertTo-Json -Depth 80 | ConvertFrom-Json -DateKind String
  $LocalizedRun.generated_at_utc = '08/11/2026 03:38:33'
  Write-Json $LocalizedRunPath $LocalizedRun
  $LocalizedRunSchema = Invoke-AgenticNativeProcess -FilePath $Node -ArgumentList @($CompanionControl,'validate-json','--schema',$RunResultSchema,'--file',$LocalizedRunPath)
  Assert-True ($LocalizedRunSchema.ExitCode -ne 0) 'RUN_RESULT schema accepted a localized authority timestamp.'
  $ZonelessRunPath = Join-Path $TempRoot 'zoneless-timestamp-run-result.json'
  $ZonelessRun = $Run | ConvertTo-Json -Depth 80 | ConvertFrom-Json -DateKind String
  $ZonelessRun.tests[0].started_at_utc = '2026-08-11T03:38:33.0000000'
  Write-Json $ZonelessRunPath $ZonelessRun
  $ZonelessRunSchema = Invoke-AgenticNativeProcess -FilePath $Node -ArgumentList @($CompanionControl,'validate-json','--schema',$RunResultSchema,'--file',$ZonelessRunPath)
  Assert-True ($ZonelessRunSchema.ExitCode -ne 0) 'RUN_RESULT schema accepted a zoneless authority timestamp.'
  $WorkerValidation = Invoke-WorkerAuthorityValidator $Valid
  Assert-True ($WorkerValidation.ExitCode -eq 0 -and (($WorkerValidation.StdOut | ConvertFrom-Json).ready -eq $true)) "Compiler output was rejected by Context Handoff authority validation: stdout=$($WorkerValidation.StdOut) stderr=$($WorkerValidation.StdErr)"
  $BeforeSecond = @(Get-OutputSnapshot $Valid)
  Start-Sleep -Milliseconds 1100
  $Second = Invoke-Compiler $Valid.Project $Valid.ReceiptPath -Apply
  Assert-True ($Second.ExitCode -eq 0 -and $Second.StdOut -match 'already_completed') 'Second identical apply was not coalesced with completed output.'
  Assert-True ((@((Compare-Object $BeforeSecond (Get-OutputSnapshot $Valid))).Count) -eq 0) 'Second identical apply changed output bytes or mtimes.'

  $BoundOutput = New-Fixture 'bound-existing-next-action' -BindExistingNextAction
  $BoundCandidate = Get-Content -LiteralPath (Join-Path $BoundOutput.Agy 'CANDIDATE_MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
  $DeclaredNextAction = $BoundCandidate.control_plane_files | Where-Object { [string]$_.path -ceq '.agy/NEXT_ACTION.json' } | Select-Object -First 1
  $InitialNextActionHash = Get-Sha256 (Join-Path $BoundOutput.Agy 'NEXT_ACTION.json')
  Assert-True ($null -ne $DeclaredNextAction -and [string]$DeclaredNextAction.sha256 -ceq $InitialNextActionHash) 'Fixture did not bind the pre-publication NEXT_ACTION bytes.'
  $BoundApply = Invoke-Compiler $BoundOutput.Project $BoundOutput.ReceiptPath -Apply
  Assert-True ($BoundApply.ExitCode -eq 0) "Compiler rejected its own intentional NEXT_ACTION publication: $($BoundApply.StdErr)"
  Assert-True ((Get-Sha256 (Join-Path $BoundOutput.Agy 'NEXT_ACTION.json')) -cne $InitialNextActionHash) 'Compiler did not replace the candidate-bound NEXT_ACTION output.'
  $BoundBeforeSecond = @(Get-OutputSnapshot $BoundOutput)
  Start-Sleep -Milliseconds 1100
  $BoundSecond = Invoke-Compiler $BoundOutput.Project $BoundOutput.ReceiptPath -Apply
  Assert-True ($BoundSecond.ExitCode -eq 0 -and $BoundSecond.StdOut -match 'already_completed') 'Bound NEXT_ACTION second apply was not verification-only.'
  Assert-True ((@((Compare-Object $BoundBeforeSecond (Get-OutputSnapshot $BoundOutput))).Count) -eq 0) 'Bound NEXT_ACTION second apply changed output bytes or mtimes.'

  $Fault = New-Fixture 'fault-rollback'
  $Seed = @{}
  foreach ($Name in @('VERIFICATION_RECEIPT.json','CLOSURE_STATE.json','RUN_RESULT.json','NEXT_ACTION.json')) {
    $Path = Join-Path $Fault.Agy $Name
    [IO.File]::WriteAllText($Path, "seed-$Name", $Utf8)
    $Seed[$Name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
  }
  $FaultResult = Invoke-Compiler $Fault.Project $Fault.ReceiptPath -Apply -FaultAfter 2
  Assert-True ($FaultResult.ExitCode -ne 0) 'Injected publication fault unexpectedly succeeded.'
  foreach ($Name in $Seed.Keys) { Assert-True -Condition ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $Fault.Agy $Name))) -ceq $Seed[$Name]) -Message "Fault rollback did not restore exact bytes: $Name" }
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $Fault.Agy '.runtime/result-authority/publication-journal.json'))) 'Fault rollback left a publication journal.'

  $Crash = New-Fixture 'crash-recovery'
  $Runtime = Join-Path $Crash.Agy '.runtime/result-authority'
  $Transaction = Join-Path $Runtime 'transactions/crashed'
  New-Item -ItemType Directory -Force -Path $Transaction | Out-Null
  $Records = @()
  $CrashExpected = @{}
  $Index = 0
  foreach ($Name in @('VERIFICATION_RECEIPT.json','CLOSURE_STATE.json','RUN_RESULT.json','NEXT_ACTION.json')) {
    $Target = Join-Path $Crash.Agy $Name
    [IO.File]::WriteAllText($Target, "before-crash-$Name", $Utf8)
    $CrashExpected[$Name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Target))
    $Backup = Join-Path $Transaction "$Index.backup"
    [IO.File]::Copy($Target, $Backup)
    [IO.File]::WriteAllText($Target, "partial-crash-$Name", $Utf8)
    $Records += [ordered]@{path=".agy/$Name";existed=$true;backup_path=".agy/.runtime/result-authority/transactions/crashed/$Index.backup";intended_sha256=Get-Sha256 $Target}
    $Index++
  }
  Write-Json (Join-Path $Runtime 'publication-journal.json') ([ordered]@{schema_version='1.0.0';token='crashed';status='writing';transaction_path='.agy/.runtime/result-authority/transactions/crashed';published_count=2;targets=$Records;updated_at_utc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')})
  $Recovered = Invoke-Compiler $Crash.Project $Crash.ReceiptPath
  Assert-True ($Recovered.ExitCode -eq 0) "Crash journal recovery failed: $($Recovered.StdErr)"
  foreach ($Name in $CrashExpected.Keys) { Assert-True -Condition ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $Crash.Agy $Name))) -ceq $CrashExpected[$Name]) -Message "Crash recovery did not restore exact bytes: $Name" }
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $Runtime 'publication-journal.json'))) 'Crash recovery left a publication journal.'

  $MaliciousJournal = New-Fixture 'malicious-journal'
  $MaliciousRuntime = Join-Path $MaliciousJournal.Agy '.runtime/result-authority'
  New-Item -ItemType Directory -Force -Path (Join-Path $MaliciousRuntime 'transactions/evil') | Out-Null
  $MaliciousCandidateBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($MaliciousJournal.CandidatePath))
  $MaliciousTargets = @(
    [ordered]@{path=$MaliciousJournal.CandidateRelative;existed=$false;backup_path=$null;intended_sha256=('0' * 64)},
    [ordered]@{path='.agy/CLOSURE_STATE.json';existed=$false;backup_path=$null;intended_sha256=('0' * 64)},
    [ordered]@{path='.agy/RUN_RESULT.json';existed=$false;backup_path=$null;intended_sha256=('0' * 64)},
    [ordered]@{path='.agy/NEXT_ACTION.json';existed=$false;backup_path=$null;intended_sha256=('0' * 64)}
  )
  Write-Json (Join-Path $MaliciousRuntime 'publication-journal.json') ([ordered]@{schema_version='1.0.0';token='evil';status='writing';transaction_path='.agy/.runtime/result-authority/transactions/evil';published_count=0;targets=$MaliciousTargets;updated_at_utc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')})
  $MaliciousResult = Invoke-Compiler $MaliciousJournal.Project $MaliciousJournal.ReceiptPath
  Assert-True ($MaliciousResult.ExitCode -ne 0 -and ($MaliciousResult.StdErr + $MaliciousResult.StdOut) -match 'RESULT_AUTHORITY_JOURNAL_INVALID') 'Journal with a product-owned target did not fail closed.'
  Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($MaliciousJournal.CandidatePath)) -ceq $MaliciousCandidateBefore) 'Rejected journal changed product bytes.'

  # The controlled pre-child delay is longer than the legacy three-second fixture budget.
  # This keeps hosted-runner startup load from consuming the process-tree assertion itself.
  $TimeoutSeconds = 15
  $TimeoutStartupDelayMilliseconds = 4500
  Assert-True ($TimeoutStartupDelayMilliseconds -gt 3000) 'Timeout fixture no longer reproduces the legacy startup-budget race.'
  $Timeout = New-Fixture 'timeout-tree' 'child' $TimeoutStartupDelayMilliseconds
  $TimeoutHandle = Start-Compiler $Timeout.Project $Timeout.ReceiptPath -Apply -TimeoutSeconds $TimeoutSeconds
  $ChildPidPath = Join-Path $Timeout.Agy '.runtime/result-authority/child.pid'
  Wait-ForFile $ChildPidPath 12
  $ChildPid = [int]([IO.File]::ReadAllText($ChildPidPath).Trim())
  Assert-True (-not $TimeoutHandle.Process.HasExited) 'Compiler timed out before the child-process readiness barrier.'
  Assert-True ($null -ne (Get-Process -Id $ChildPid -ErrorAction SilentlyContinue)) 'Timeout fixture child was not running before the bounded compiler deadline.'
  $TimeoutResult = Complete-Compiler $TimeoutHandle 25
  Assert-True ($TimeoutResult.ExitCode -ne 0 -and ($TimeoutResult.StdErr + $TimeoutResult.StdOut) -match 'RESULT_AUTHORITY_TIMEOUT') "Worker timeout did not fail with the timeout code: stdout=$($TimeoutResult.StdOut) stderr=$($TimeoutResult.StdErr)"
  Wait-ForProcessExit $ChildPid 5
  Assert-True ($null -eq (Get-Process -Id $ChildPid -ErrorAction SilentlyContinue)) 'Timed-out worker left its child process running.'
  foreach ($Name in @('VERIFICATION_RECEIPT.json','CLOSURE_STATE.json','RUN_RESULT.json','NEXT_ACTION.json')) { Assert-True (-not (Test-Path -LiteralPath (Join-Path $Timeout.Agy $Name))) "Timeout published $Name." }
  Write-Validator $Timeout.Project 'quick'
  $TimeoutRecovery = Invoke-Compiler $Timeout.Project $Timeout.ReceiptPath -Apply -TimeoutSeconds 10
  Assert-True ($TimeoutRecovery.ExitCode -eq 0) 'Compiler lock was not reusable after timeout.'

  $Same = New-Fixture 'same-fingerprint' 'barrier'
  $FirstSame = Start-Compiler $Same.Project $Same.ReceiptPath -Apply -TimeoutSeconds 10
  Wait-ForFile (Join-Path $Same.Agy '.runtime/result-authority/validator-count.txt')
  $SecondSame = Start-Compiler $Same.Project $Same.ReceiptPath -Apply -TimeoutSeconds 10
  $SecondSameResult = Complete-Compiler $SecondSame 10
  [IO.File]::WriteAllText((Join-Path $Same.Agy '.runtime/result-authority/validator-release.txt'), 'release', $Utf8)
  Assert-True ($SecondSameResult.ExitCode -eq 0 -and $SecondSameResult.StdOut -match 'coalesced_active') "Same-fingerprint request was not coalesced: stdout=$($SecondSameResult.StdOut) stderr=$($SecondSameResult.StdErr)"
  $FirstSameResult = Complete-Compiler $FirstSame 15
  Assert-True ($FirstSameResult.ExitCode -eq 0) 'Owning same-fingerprint compiler failed.'
  Assert-True (@(Get-Content -LiteralPath (Join-Path $Same.Agy '.runtime/result-authority/validator-count.txt')).Count -eq 1) 'Same-fingerprint coalescing launched more than one worker.'

  $AuthorityRace = New-Fixture 'authority-snapshot-race' 'slow' 3000
  $RaceOwner = Start-Compiler $AuthorityRace.Project $AuthorityRace.ReceiptPath -Apply -TimeoutSeconds 10
  Wait-ForFile (Join-Path $AuthorityRace.Agy '.runtime/result-authority/validator-count.txt')
  $ActiveTask = Join-Path $AuthorityRace.Agy 'inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ActiveTask) | Out-Null
  [IO.File]::WriteAllText($ActiveTask, 'mutated payload authority', $Utf8)
  $RaceResult = Complete-Compiler $RaceOwner 15
  Assert-True ($RaceResult.ExitCode -ne 0 -and ($RaceResult.StdErr + $RaceResult.StdOut) -match 'RESULT_AUTHORITY_INPUT_CHANGED') "Payload-authority mutation race was not rejected by fingerprint revalidation: stdout=$($RaceResult.StdOut) stderr=$($RaceResult.StdErr)"
  foreach ($Name in @('VERIFICATION_RECEIPT.json','CLOSURE_STATE.json','RUN_RESULT.json','NEXT_ACTION.json')) { Assert-True (-not (Test-Path -LiteralPath (Join-Path $AuthorityRace.Agy $Name))) "Authority race published $Name." }

  $Latest = New-Fixture 'latest-wins' 'slow' 6000
  $FirstLatest = Start-Compiler $Latest.Project $Latest.ReceiptPath -Apply -TimeoutSeconds 10
  Wait-ForFile (Join-Path $Latest.Agy '.runtime/result-authority/validator-count.txt')
  [void](Update-FixtureAuthority $Latest)
  $SecondLatest = Start-Compiler $Latest.Project $Latest.ReceiptPath -Apply -TimeoutSeconds 10
  Wait-ForFile (Join-Path $Latest.Agy '.runtime/result-authority/pending.json')
  [void](Update-FixtureAuthority $Latest)
  # The eventual owner still executes the deliberately slow validator. Give that
  # worker a bounded startup margin in Unicode/space detached worktrees; the
  # dedicated timeout-tree case above remains the hard timeout regression.
  $LatestOwnerTimeoutSeconds = 20
  Assert-True ($LatestOwnerTimeoutSeconds -gt 10 -and $LatestOwnerTimeoutSeconds -lt 120) 'Latest-wins owner timeout is not bounded below the production default.'
  $ThirdLatest = Start-Compiler $Latest.Project $Latest.ReceiptPath -Apply -TimeoutSeconds $LatestOwnerTimeoutSeconds
  $SecondLatestResult = Complete-Compiler $SecondLatest 8
  Assert-True ($SecondLatestResult.ExitCode -eq 0 -and $SecondLatestResult.StdOut -match 'superseded') "Intermediate different-fingerprint request was not cancelled by latest-wins coalescing: stdout=$($SecondLatestResult.StdOut) stderr=$($SecondLatestResult.StdErr)"
  $FirstLatestResult = Complete-Compiler $FirstLatest 12
  Assert-True ($FirstLatestResult.ExitCode -ne 0 -and ($FirstLatestResult.StdErr + $FirstLatestResult.StdOut) -match 'RESULT_AUTHORITY_(?:INPUT_CHANGED|RECEIPT_CHANGED)') "Latest-wins owner did not reject its superseded receipt: stdout=$($FirstLatestResult.StdOut) stderr=$($FirstLatestResult.StdErr)"
  $ThirdLatestResult = Complete-Compiler $ThirdLatest ($LatestOwnerTimeoutSeconds + 8)
  Assert-True ($ThirdLatestResult.ExitCode -eq 0) "Latest different-fingerprint request failed: $($ThirdLatestResult.StdErr)"
  Assert-True (@(Get-Content -LiteralPath (Join-Path $Latest.Agy '.runtime/result-authority/validator-count.txt')).Count -eq 2) 'Latest-wins regression did not execute exactly stale-owner plus latest worker.'

  if ($IsWindows) {
    $Reparse = New-Fixture 'reparse-evidence'
    $Outside = Join-Path $TempRoot 'reparse-outside'
    New-Item -ItemType Directory -Force -Path $Outside | Out-Null
    $OutsideFile = Join-Path $Outside 'test.log'
    [IO.File]::WriteAllText($OutsideFile, 'reparse evidence', $Utf8)
    (Get-Item $OutsideFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-3)
    $Link = Join-Path $Reparse.Agy 'verification/link'
    try {
      New-Item -ItemType SymbolicLink -Path $Link -Target $Outside | Out-Null
      $Receipt = Get-Content -LiteralPath $Reparse.ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -DateKind String
      $Receipt.tests[0].evidence_path = '.agy/verification/link/test.log'
      $Receipt.tests[0].evidence_sha256 = Get-Sha256 $OutsideFile
      $Receipt.tests[0].evidence_size_bytes = [long](Get-Item $OutsideFile).Length
      Write-Json $Reparse.ReceiptPath $Receipt
      $ReparseResult = Invoke-Compiler $Reparse.Project $Reparse.ReceiptPath
      Assert-True ($ReparseResult.ExitCode -ne 0 -and ($ReparseResult.StdErr + $ReparseResult.StdOut) -match 'RESULT_AUTHORITY_TEST_EVIDENCE') 'Reparse-point evidence was accepted.'
      Assert-NoCompilerWrites $Reparse
    }
    catch [System.UnauthorizedAccessException] { Write-Warning 'Symlink privilege unavailable; reparse executable probe skipped.' }
  }

  $SourceStatusAfter = (& git -C $Root status --porcelain=v2 -z --untracked-files=all)
  Assert-True ([string]$SourceStatusAfter -ceq [string]$SourceStatusBefore) 'Result-authority regression modified the source checkout.'
  Write-Host "Result-authority compiler transaction contract passed. Assertions=$Assertions; live_writes=0; source_changed=false"
}
finally {
  foreach ($Handle in @($CompilerHandles)) {
    try {
      if (-not $Handle.Process.HasExited) { $Handle.Process.Kill($true); [void]$Handle.Process.WaitForExit(5000) }
      $Handle.Process.Dispose()
    }
    catch {}
  }
  $CompilerHandles.Clear()
  if (Test-Path -LiteralPath $TempRoot -PathType Container) {
    $Resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TempRoot).Path)
    if (-not $Resolved.StartsWith($TempBase, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $Resolved) -cnotmatch '^agentic-result-authority-[0-9a-f]{32}$') { throw "Unsafe cleanup target: $Resolved" }
    $Removed = $false
    for ($Attempt = 0; $Attempt -lt 20 -and -not $Removed; $Attempt++) {
      try { Remove-Item -LiteralPath $Resolved -Recurse -Force; $Removed = $true }
      catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $Removed) { throw "Unable to remove exact compiler fixture after bounded retries: $Resolved" }
  }
}
