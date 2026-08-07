[CmdletBinding()]
param(
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$KitRoot = $PSScriptRoot,
  [switch]$SkipPull
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$TransportLibraryCandidates = @(
  (Join-Path $KitRoot 'lib\GitHubTransport.ps1'),
  (Join-Path $PSScriptRoot 'GitHubTransport.ps1')
)
$TransportLibrary = $TransportLibraryCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (!$TransportLibrary) {
  throw 'GitHub transport helper is missing.'
}
. $TransportLibrary

Initialize-GitHubCredentialHelper | Out-Null
$Transport = Test-GitHubTransport -WorkingDirectory $KitRoot
Write-Host "GitHub transport preflight passed with profile: $($Transport.TransportProfile)" -ForegroundColor Green

$PwshExe = (Get-Command pwsh -ErrorAction Stop).Source
$LocalScript = Join-Path $PSScriptRoot 'Run-AgenticPipeline-v1.2.6-Upgrade-Local.ps1'
$LocalArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$LocalScript,'-RepoRoot',$RepoRoot,'-KitRoot',$KitRoot)
if ($SkipPull) { $LocalArgs += '-SkipPull' }
$LocalResult = Invoke-TransportNative -FilePath $PwshExe -ArgumentList $LocalArgs
$LocalResult.Lines | ForEach-Object { Write-Host $_ }

try {
  $PublishScript = Join-Path $PSScriptRoot 'Publish-AgenticPipeline-v1.2.6-GitHub.ps1'
  $PublishResult = Invoke-TransportNative -FilePath $PwshExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PublishScript,'-RepoRoot',$RepoRoot)
  $PublishResult.Lines | ForEach-Object { Write-Host $_ }
}
catch {
  Write-Warning 'Local upgrade completed, but GitHub publication did not complete.'
  Write-Warning 'The local repository and release artifacts remain available. Re-run Publish-AgenticPipeline-v1.2.6-GitHub.ps1 after network recovery.'
  throw
}

Write-Host 'AGENTIC PIPELINE 1.2.6 LOCAL + GITHUB UPDATE COMPLETED.' -ForegroundColor Green
