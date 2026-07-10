param(
  [string]$TargetRoot = ""
)

$ErrorActionPreference = "Stop"

throw @"
Apply-AgenticPipeline-v1.1.1.ps1 is deprecated and intentionally blocked.

Reason: the legacy installer embedded stale runtime content and could downgrade a v1.2 project.

Use the current installer instead:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\Initialize-AgenticProject.ps1 -Mode New -TargetRoot <path> -Apply
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\Initialize-AgenticProject.ps1 -Mode Adopt -TargetRoot <path> -Apply

Requested TargetRoot: $TargetRoot
"@
