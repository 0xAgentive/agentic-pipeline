$ErrorActionPreference = "Stop"

$Hooks = @(
  ".agents\hooks\guard_preflight.ps1",
  ".agents\hooks\guard_context_budget.ps1",
  ".agents\hooks\guard_offline_local_only.ps1",
  ".agents\hooks\agy_checkpoint.ps1"
)

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

function Get-PowerShellExecutable {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) {
    return $pwsh.Source
  }

  $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
  if ($windowsPowerShell) {
    return $windowsPowerShell.Source
  }

  throw "No PowerShell executable found. Expected pwsh or powershell."
}

$Shell = Get-PowerShellExecutable
$ShellName = [System.IO.Path]::GetFileName($Shell)

$Failed = @()

foreach ($Hook in $Hooks) {
  if (!(Test-Path $Hook)) {
    $Failed += "$Hook missing"
    continue
  }

  $Args = @("-NoProfile")

  if ($ShellName -match "^(?i:powershell)(\.exe)?$") {
    $Args += @("-ExecutionPolicy", "Bypass")
  }

  $Args += @("-File", $Hook)

  & $Shell @Args

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