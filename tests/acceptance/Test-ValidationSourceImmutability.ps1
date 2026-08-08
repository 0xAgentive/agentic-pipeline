[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [string]$OutputRoot = '',
  [int]$Runs = 2
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $Root 'scripts\windows\common\NativeProcess.ps1')
if ($Runs -lt 1) { throw 'Runs must be at least 1.' }
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('agentic-source-immutability-' + [Guid]::NewGuid().ToString('N'))
$Candidate = Join-Path $Temp 'detached candidate with spaces юникод'
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $Temp 'evidence' }
$Output = [IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Force -Path $Temp, $Output | Out-Null

function Invoke-Checked([string]$FilePath, [string[]]$Arguments, [string]$Name) {
  $Result = Invoke-AgenticNativeProcess -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $Candidate
  [IO.File]::WriteAllText((Join-Path $Output ($Name + '.stdout.log')), $Result.StdOut, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $Output ($Name + '.stderr.log')), $Result.StdErr, [Text.UTF8Encoding]::new($false))
  if ($Result.ExitCode -ne 0) { throw "$Name failed with exit code $($Result.ExitCode): $($Result.StdErr)" }
  return $Result
}

function Get-TrackedSnapshot {
  $List = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-c','core.quotepath=false','-C',$Candidate,'ls-files','-z')
  Assert-AgenticNativeSuccess -Result $List -Description 'git ls-files'
  $Rows = New-Object System.Collections.Generic.List[object]
  foreach ($Relative in (Split-AgenticNulList -Text $List.StdOut)) {
    $Full = Join-Path $Candidate $Relative
    if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { throw "Tracked file missing during validation: $Relative" }
    $Info = Get-Item -LiteralPath $Full
    [void]$Rows.Add([pscustomobject]@{ path = $Relative; size_bytes = [int64]$Info.Length; sha256 = (Get-FileHash -LiteralPath $Full -Algorithm SHA256).Hash.ToLowerInvariant() })
  }
  return @($Rows.ToArray() | Sort-Object path)
}

function Compare-Snapshot([object[]]$Before, [object[]]$After) {
  $BeforeMap = @{}; foreach ($Row in $Before) { $BeforeMap[[string]$Row.path] = "$($Row.size_bytes):$($Row.sha256)" }
  $AfterMap = @{}; foreach ($Row in $After) { $AfterMap[[string]$Row.path] = "$($Row.size_bytes):$($Row.sha256)" }
  $Paths = @($BeforeMap.Keys + $AfterMap.Keys | Sort-Object -Unique)
  return @($Paths | Where-Object { -not $BeforeMap.ContainsKey($_) -or -not $AfterMap.ContainsKey($_) -or $BeforeMap[$_] -ne $AfterMap[$_] })
}

function Assert-Clean([string]$Step) {
  $Status = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Candidate,'status','--porcelain=v2','-z','--untracked-files=all')
  Assert-AgenticNativeSuccess -Result $Status -Description 'git status'
  if ($Status.StdOut.Length -ne 0) { throw "$Step left the detached validation worktree dirty." }
}

$HeadResult = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Root,'rev-parse','HEAD')
Assert-AgenticNativeSuccess -Result $HeadResult -Description 'git rev-parse HEAD'
$Head = $HeadResult.StdOut.Trim()
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$Node = (Get-Command node -ErrorAction Stop).Source
$PreviousNoByteCode = $env:PYTHONDONTWRITEBYTECODE
$PreviousCachePrefix = $env:PYTHONPYCACHEPREFIX

try {
  $Add = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Root,'worktree','add','--detach',$Candidate,$Head)
  Assert-AgenticNativeSuccess -Result $Add -Description 'git worktree add'
  $env:PYTHONDONTWRITEBYTECODE = '1'
  $env:PYTHONPYCACHEPREFIX = Join-Path $Temp 'python-cache'
  Assert-Clean 'initial state'

  $Sentinel = Join-Path $Temp 'one-byte-sentinel.bin'
  [IO.File]::WriteAllBytes($Sentinel, [byte[]](1,2,3))
  $SentinelBefore = (Get-FileHash -LiteralPath $Sentinel -Algorithm SHA256).Hash
  [IO.File]::WriteAllBytes($Sentinel, [byte[]](1,2,3,4))
  $SentinelAfter = (Get-FileHash -LiteralPath $Sentinel -Algorithm SHA256).Hash
  if ($SentinelBefore -eq $SentinelAfter) { throw 'Negative one-byte mutation probe was not detected.' }

  $Steps = @(
    [pscustomobject]@{ name='compatibility'; file=$Pwsh; args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Candidate 'tests\acceptance\Test-ProgressGuardMigrationCompatibility.ps1'),'-RepoRoot',$Candidate) },
    [pscustomobject]@{ name='powershell-runtime'; file=$Pwsh; args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Candidate 'scripts\windows\Test-PowerShellRuntimeContracts.ps1'),'-RepoRoot',$Candidate) },
    [pscustomobject]@{ name='operational-deployment'; file=$Pwsh; args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Candidate 'scripts\windows\Test-OperationalDeployment.ps1'),'-RepoRoot',$Candidate) },
    [pscustomobject]@{ name='distribution-integrity'; file=$Pwsh; args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Candidate 'scripts\windows\Test-DistributionIntegrity.ps1'),'-RepoRoot',$Candidate,'-WorkingTreeWhitespacePolicy','advisory') },
    [pscustomobject]@{ name='hard-package'; file=$Pwsh; args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Candidate 'scripts\windows\Validate-AgenticPipelinePackage.ps1'),'-RepoRoot',$Candidate,'-Strict') },
    [pscustomobject]@{ name='known-failure-node'; file=$Node; args=@((Join-Path $Candidate 'tests\regression\known-failure-regression.cjs'),$Candidate) },
    [pscustomobject]@{ name='diff-check'; file='git'; args=@('-C',$Candidate,'diff','--check') }
  )

  $Results = New-Object System.Collections.Generic.List[object]
  for ($Run = 1; $Run -le $Runs; $Run++) {
    foreach ($Step in $Steps) {
      $Before = @(Get-TrackedSnapshot)
      $LogName = ('run-{0:D2}-{1}' -f $Run, $Step.name)
      Invoke-Checked -FilePath $Step.file -Arguments $Step.args -Name $LogName | Out-Null
      $After = @(Get-TrackedSnapshot)
      $Delta = @(Compare-Snapshot $Before $After)
      if ($Delta.Count -gt 0) { throw "$($Step.name) modified tracked source bytes: $($Delta -join ', ')" }
      Assert-Clean "$($Step.name) run $Run"
      [void]$Results.Add([pscustomobject]@{ run=$Run; validator=$Step.name; status='PASS'; tracked_files=$After.Count; byte_delta=0 })
    }
  }
  $Report = [ordered]@{ schema_version='1.0.0'; status='PASS'; source_commit=$Head; runs=$Runs; negative_one_byte_probe='PASS'; validators=$Results.ToArray() }
  [IO.File]::WriteAllText((Join-Path $Output 'VALIDATION_SOURCE_IMMUTABILITY.json'), ($Report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
  Write-Host "Validation source immutability passed for $Runs full runs."
}
finally {
  $env:PYTHONDONTWRITEBYTECODE = $PreviousNoByteCode
  $env:PYTHONPYCACHEPREFIX = $PreviousCachePrefix
  if (Test-Path -LiteralPath $Candidate -PathType Container) {
    $Remove = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Root,'worktree','remove','--force',$Candidate)
    if ($Remove.ExitCode -ne 0) { Write-Warning "Temporary worktree cleanup failed: $($Remove.StdErr)" }
  }
  if ($Output.StartsWith($Temp, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
  else { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
}
