[CmdletBinding()]
param(
  [string]$KitRoot = $PSScriptRoot,
  [string]$RepositoryUrl = 'https://github.com/0xAgentive/agentic-pipeline.git'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$LibraryCandidates = @(
  (Join-Path $KitRoot 'lib\GitHubTransport.ps1'),
  (Join-Path $PSScriptRoot 'GitHubTransport.ps1')
)
$Library = $LibraryCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (!$Library) {
  throw 'GitHub transport helper is missing.'
}
. $Library

$Result = Test-GitHubTransport -RepositoryUrl $RepositoryUrl -WorkingDirectory $KitRoot
Write-Host 'GITHUB TRANSPORT PREFLIGHT PASSED.' -ForegroundColor Green
Write-Host "Transport profile: $($Result.TransportProfile)"
Write-Host "Attempts: $($Result.Attempts)"
