[CmdletBinding()]
param([string]$InstallRoot = "$env:LOCALAPPDATA\AgenticPipeline\ActionBridge", [switch]$RemoveFiles)
$ErrorActionPreference = 'Stop'
Unregister-ScheduledTask -TaskName 'AgenticPipelineCompanionActionBridge' -Confirm:$false -ErrorAction SilentlyContinue
if ($RemoveFiles) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'Companion Action Bridge uninstalled.'
