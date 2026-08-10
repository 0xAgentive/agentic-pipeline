[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [string]$EvidenceRoot = ''
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $Root 'scripts\windows\common\NativeProcess.ps1')
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $EvidenceRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-known-failures-' + [Guid]::NewGuid().ToString('N'))
}
$Evidence = [IO.Path]::GetFullPath($EvidenceRoot)
New-Item -ItemType Directory -Force -Path $Evidence | Out-Null
$Failures = New-Object System.Collections.Generic.List[object]
$Passes = New-Object System.Collections.Generic.List[object]
$Utf8 = [Text.UTF8Encoding]::new($false)

function Add-Result([string]$Id, [bool]$Passed, [string]$Details) {
  $Row = [pscustomobject]@{ id=$Id; details=$Details }
  if ($Passed) { [void]$Passes.Add($Row) } else { [void]$Failures.Add($Row) }
}

function Save-NativeResult([string]$Name, [object]$Result) {
  [IO.File]::WriteAllText((Join-Path $Evidence ($Name + '.stdout.log')), [string]$Result.StdOut, $Utf8)
  [IO.File]::WriteAllText((Join-Path $Evidence ($Name + '.stderr.log')), [string]$Result.StdErr, $Utf8)
}

try {
  $PlaybookPath = Join-Path $Root 'tests\regression\KNOWN_FAILURE_PLAYBOOK_v1.2.17.json'
  $Playbook = Get-Content -LiteralPath $PlaybookPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $Cases = @($Playbook.cases)
  $ExpectedIds = @(1..70 | ForEach-Object { 'KF-{0:D3}' -f $_ })
  $ActualIds = @($Cases.id | Sort-Object)
  $ShapeOk = (
    [string]$Playbook.ecosystem_version -eq '1.2.17' -and
    [int]$Playbook.reviewed_count -eq 70 -and
    $Cases.Count -eq 70 -and
    @(Compare-Object -ReferenceObject $ExpectedIds -DifferenceObject $ActualIds).Count -eq 0 -and
    @($Cases | Where-Object { $_.review_status -ne 'reviewed' -or $_.material -ne $true -or [string]::IsNullOrWhiteSpace([string]$_.evidence) }).Count -eq 0
  )
  Add-Result 'PLAYBOOK-SHAPE' $ShapeOk 'Exactly KF-001..KF-070 are reviewed, material and evidence-bound.'
  Add-Result 'PLAYBOOK-EXECUTABLE-COUNT' (@($Cases | Where-Object verification_mode -eq 'executable_regression').Count -eq 42) '42 cases have executable regressions.'
  Add-Result 'PLAYBOOK-LIVE-COUNT' (@($Cases | Where-Object verification_mode -eq 'live_acceptance').Count -eq 28) '28 cases require final live acceptance evidence.'
}
catch {
  Add-Result 'PLAYBOOK-SHAPE' $false $_.Exception.Message
}

$Node = (Get-Command node -ErrorAction Stop).Source
$NodeResult = Invoke-AgenticNativeProcess -FilePath $Node -ArgumentList @((Join-Path $Root 'tests\regression\finalization-known-failure-regression.cjs'), $Root) -WorkingDirectory $Root
Save-NativeResult 'portable-regressions' $NodeResult
Add-Result 'PORTABLE-REGRESSIONS' ($NodeResult.ExitCode -eq 0) "exit=$($NodeResult.ExitCode)"

$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$WindowsResult = Invoke-AgenticNativeProcess -FilePath $Pwsh -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'scripts\windows\Test-FinalizationWindowsRegressions.ps1'), '-RepoRoot', $Root) -WorkingDirectory $Root
Save-NativeResult 'windows-regressions' $WindowsResult
Add-Result 'WINDOWS-REGRESSIONS' ($WindowsResult.ExitCode -eq 0) "exit=$($WindowsResult.ExitCode)"

[object[]]$FailureArray = $Failures.ToArray()
[object[]]$PassArray = $Passes.ToArray()
$Report = [ordered]@{
  schema_version = '1.0.0'
  ecosystem_version = '1.2.17'
  status = if ($FailureArray.Count -eq 0) { 'PASS' } else { 'FAIL' }
  passes = $PassArray
  failures = $FailureArray
}
[IO.File]::WriteAllText((Join-Path $Evidence 'KNOWN_FAILURE_REGRESSION_RESULT.json'), ($Report | ConvertTo-Json -Depth 12), $Utf8)
$Report | ConvertTo-Json -Depth 12 | Write-Host
if ($FailureArray.Count -gt 0) { exit 1 }
Write-Host 'Known-failure regression playbook passed: 70/70 reviewed, 42 executable checks passed.'
exit 0
