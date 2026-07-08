$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

$Required = @(
  ".agents\AGENTS.md",
  ".agy\PHASE_STATUS.json",
  ".cbmignore"
)

$Missing = @()

foreach ($Path in $Required) {
  if (!(Test-Path $Path)) {
    $Missing += $Path
  }
}

if ($Missing.Count -gt 0) {
  Write-Error ("Pipeline preflight failed. Missing: " + ($Missing -join ", "))
  exit 1
}

Write-Host "Pipeline preflight OK."
exit 0