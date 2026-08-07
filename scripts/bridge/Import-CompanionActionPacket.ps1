[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$PacketPath,
  [string]$RegistryPath = "$env:USERPROFILE\.agentic-pipeline\project-registry.json",
  [string]$StateRoot = "$env:USERPROFILE\.agentic-pipeline\action-bridge"
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Python = (Get-Command python -ErrorAction Stop).Source
$Bridge = Join-Path $PSScriptRoot 'companion_action_bridge.py'
& $Python $Bridge import --packet $PacketPath --registry $RegistryPath --state-root $StateRoot
if ($LASTEXITCODE -ne 0) { throw 'Companion action packet import failed.' }
