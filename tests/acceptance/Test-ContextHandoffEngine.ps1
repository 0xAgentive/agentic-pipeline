[CmdletBinding()]
param([string]$RepoRoot='.')

Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $Root 'scripts\windows\common\NativeProcess.ps1')
$Version=Get-Content -LiteralPath (Join-Path $Root 'VERSION.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Integration=Join-Path $Root ("integrations\companion-handoff-{0}" -f [string]$Version.context_handoff_version)
$Source=Join-Path $Integration 'source'
$Runner=Join-Path $Source 'install\run_tests.py'
if(-not(Test-Path -LiteralPath $Runner -PathType Leaf)){throw "Context Handoff test runner is missing: $Runner"}
if(-not $IsWindows){
  $WorkflowText=[IO.File]::ReadAllText((Join-Path $Root '.github\workflows\validate.yml'))
  if($WorkflowText -notmatch '(?s)validate-windows-unicode:.*?Full Windows distribution integrity.*?Test-DistributionIntegrity\.ps1'){
    throw 'Context Handoff engine delegation is not backed by the full windows-latest Distribution Integrity job.'
  }
  Write-Host 'Context Handoff engine Windows regression delegated to the full windows-latest distribution job.'
  exit 0
}

$Python=Get-Command python -ErrorAction SilentlyContinue
if(-not $Python){$Python=Get-Command python3 -ErrorAction Stop}

function Get-SourceSnapshot {
  $Rows=New-Object System.Collections.Generic.List[string]
  Get-ChildItem -LiteralPath $Source -Recurse -File | Sort-Object FullName | ForEach-Object {
    $Relative=[IO.Path]::GetRelativePath($Source,$_.FullName).Replace('\','/')
    [void]$Rows.Add("$Relative`t$($_.Length)`t$($_.LastWriteTimeUtc.Ticks)`t$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())")
  }
  return @($Rows.ToArray())
}

$BytecodeBefore=@(Get-ChildItem -LiteralPath $Source -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue)
if($BytecodeBefore.Count -ne 0){throw 'Context Handoff source already contains __pycache__.'}
$Before=Get-SourceSnapshot
$Previous=$env:PYTHONDONTWRITEBYTECODE
try {
  $env:PYTHONDONTWRITEBYTECODE='1'
  $Result=Invoke-AgenticNativeProcess -FilePath $Python.Source -ArgumentList @('-B',$Runner) -WorkingDirectory $Source
}
finally {
  $env:PYTHONDONTWRITEBYTECODE=$Previous
}
$Result.StdOut | Write-Host
if(-not[string]::IsNullOrWhiteSpace($Result.StdErr)){$Result.StdErr | Write-Host}
Assert-AgenticNativeSuccess -Result $Result -Description 'Context Handoff engine regression'
if($Result.StdOut -notmatch 'Test Summary:\s*73 PASS,\s*0 FAIL'){throw 'Context Handoff engine did not report 73 PASS / 0 FAIL.'}
$After=Get-SourceSnapshot
if(@(Compare-Object $Before $After -CaseSensitive).Count -ne 0){throw 'Context Handoff engine regression modified source bytes or mtimes.'}
if(@(Get-ChildItem -LiteralPath $Source -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue).Count -ne 0){throw 'Context Handoff engine regression created __pycache__.'}
Write-Host 'Context Handoff engine regression passed. Tests=73; source_changed=false; pycache=0'
