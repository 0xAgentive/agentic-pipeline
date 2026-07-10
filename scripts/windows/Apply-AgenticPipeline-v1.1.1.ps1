param(
  [string]$TargetRoot = "$env:USERPROFILE\Documents\antigravity\H10 Athlete Cardio Lab",
  [string]$TemplateRoot = "$env:USERPROFILE\Documents\antigravity\_templates\agy-project-base",
  [switch]$UpdateMcpConfig
)

$ErrorActionPreference = "Stop"

throw @"
Apply-AgenticPipeline-v1.1.1.ps1 is deprecated and intentionally blocked.

Reason: the legacy installer embedded stale fastpatch/runtime content and could downgrade a v1.2 project.

Use the current v1.2 migration tool instead:
  Update-Polar-AgenticFramework-v1.2.ps1

Requested TargetRoot: $TargetRoot
Requested TemplateRoot: $TemplateRoot
"@
