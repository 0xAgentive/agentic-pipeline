$ErrorActionPreference = "Stop"

$Hooks = @(
  ".agents\hooks\guard_preflight.ps1",
  ".agents\hooks\guard_context_budget.ps1",
  ".agents\hooks\guard_offline_local_only.ps1",
  ".agents\hooks\agy_checkpoint.ps1"
)

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

$Failed = @()

foreach ($Hook in $Hooks) {
  if (!(Test-Path $Hook)) {
    $Failed += "$Hook missing"
    continue
  }

  powershell -NoProfile -ExecutionPolicy Bypass -File $Hook
  if ($LASTEXITCODE -ne 0) {
    $Failed += "$Hook exited with $LASTEXITCODE"
  }
}

if ($Failed.Count -gt 0) {
  Write-Host "Hook contract failed:"
  $Failed | ForEach-Object { Write-Host "- $_" }
  exit 1
}

Write-Host "Hook contract OK."
exit 0