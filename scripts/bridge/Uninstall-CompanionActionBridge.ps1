[CmdletBinding()]
param(
  [string]$InstallRoot = "$env:LOCALAPPDATA\AgenticPipeline\ActionBridge",
  [string]$TaskName = 'AgenticPipelineCompanionActionBridge',
  [switch]$RemoveFiles
)
$ErrorActionPreference = 'Stop'
$WatcherTaskName = if ($TaskName.EndsWith('-Watcher')) { $TaskName } else { "$TaskName-Watcher" }
$FallbackTaskName = if ($TaskName.EndsWith('-Watcher')) { $TaskName.Substring(0, $TaskName.Length - 8) + '-Fallback' } else { "$TaskName-Fallback" }

Unregister-ScheduledTask -TaskName $WatcherTaskName -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $FallbackTaskName -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

if ($RemoveFiles) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'Companion Action Bridge uninstalled.'
