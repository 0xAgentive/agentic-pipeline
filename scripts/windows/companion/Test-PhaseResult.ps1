[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$PipelineRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline"
)
$ErrorActionPreference = "Stop"
$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$NodeCore = Join-Path $PipelineRoot "scripts\companion\companion-control.cjs"
if (!(Test-Path -LiteralPath $NodeCore -PathType Leaf)) { throw "Companion control script not found: $NodeCore" }
& node $NodeCore validate-result --project-root $Project
exit $LASTEXITCODE
