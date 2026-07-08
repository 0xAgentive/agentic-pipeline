$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

$required = @(
  ".agents\AGENTS.md",
  ".agy\PHASE_STATUS.json",
  ".cbmignore",
  "AGENTS.md"
)

$missing = @()
foreach ($path in $required) {
  if (!(Test-Path $path)) { $missing += $path }
}

if ($missing.Count -gt 0) {
  Write-Host "Pipeline preflight failed. Missing files:"
  $missing | ForEach-Object { Write-Host "- $_" }
  exit 1
}

try {
  Get-Content ".agy\PHASE_STATUS.json" -Raw | ConvertFrom-Json | Out-Null
} catch {
  Write-Host "Pipeline preflight failed. PHASE_STATUS.json is not valid JSON."
  exit 1
}

Write-Host "Pipeline preflight OK."
exit 0
