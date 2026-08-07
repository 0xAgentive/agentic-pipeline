[CmdletBinding()]
param(
  [string]$Inbox = "$env:USERPROFILE\Downloads",
  [string]$RegistryPath = "$env:USERPROFILE\.agentic-pipeline\project-registry.json",
  [string]$StateRoot = "$env:USERPROFILE\.agentic-pipeline\action-bridge"
)
$ErrorActionPreference = 'Stop'
$Python = (Get-Command python -ErrorAction Stop).Source
$Bridge = Join-Path $PSScriptRoot 'companion_action_bridge.py'
& $Python $Bridge scan --inbox $Inbox --registry $RegistryPath --state-root $StateRoot
if ($LASTEXITCODE -notin @(0,1)) { throw 'Companion Action Bridge worker failed.' }
