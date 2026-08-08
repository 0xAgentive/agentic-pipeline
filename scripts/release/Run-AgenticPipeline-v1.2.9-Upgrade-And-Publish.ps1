[CmdletBinding()]
param(
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$KitRoot = $PSScriptRoot,
  [string]$ProjectRoot = '',
  [string]$ProjectId = '',
  [string]$LogicalName = '',
  [string]$DeploymentRoot = '',
  [string]$HandoffRoot = 'C:\Scripts\AntigravityProjects\companion-handoff',
  [switch]$SkipPull,
  [switch]$SkipProjectDeployment,
  [switch]$OpenFolder
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
$LocalScript = Join-Path $PSScriptRoot 'Run-AgenticPipeline-v1.2.9-Upgrade-Local.ps1'
$LocalArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$LocalScript,'-RepoRoot',$RepoRoot,'-KitRoot',$KitRoot)
if ($SkipPull) { $LocalArgs += '-SkipPull' }
$LocalResult = Invoke-TransportNative -FilePath $PwshExe -ArgumentList $LocalArgs
$LocalResult.Lines | ForEach-Object { Write-Host $_ }

try {
  $PublishScript = Join-Path $PSScriptRoot 'Publish-AgenticPipeline-v1.2.9-GitHub.ps1'
  $PublishResult = Invoke-TransportNative -FilePath $PwshExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PublishScript,'-RepoRoot',$RepoRoot)
  $PublishResult.Lines | ForEach-Object { Write-Host $_ }
}
catch {
  Write-Warning 'Local upgrade completed, but GitHub publication did not complete.'
  Write-Warning 'The local repository and release artifacts remain available. Re-run Publish-AgenticPipeline-v1.2.9-GitHub.ps1 after network recovery.'
  throw
}

if(-not$SkipProjectDeployment){if([string]::IsNullOrWhiteSpace($ProjectRoot)){throw 'Project deployment requires -ProjectRoot or use -SkipProjectDeployment.'};$DeployScript=Join-Path $RepoRoot 'scripts\release\Complete-AgenticPipeline-v1.2.9-Deployment.ps1';$DeployArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$DeployScript,'-RepoRoot',$RepoRoot,'-ProjectRoot',$ProjectRoot,'-HandoffRoot',$HandoffRoot);if(-not[string]::IsNullOrWhiteSpace($ProjectId)){$DeployArgs+=@('-ProjectId',$ProjectId)};if(-not[string]::IsNullOrWhiteSpace($LogicalName)){$DeployArgs+=@('-LogicalName',$LogicalName)};if(-not[string]::IsNullOrWhiteSpace($DeploymentRoot)){$DeployArgs+=@('-DeploymentRoot',$DeploymentRoot)};if($OpenFolder){$DeployArgs+='-OpenFolder'};$DeployResult=Invoke-TransportNative -FilePath $PwshExe -ArgumentList $DeployArgs;$DeployResult.Lines|ForEach-Object{Write-Host $_}}
Write-Host 'AGENTIC PIPELINE 1.2.9 GLOBAL FIX COMPLETED.' -ForegroundColor Green
