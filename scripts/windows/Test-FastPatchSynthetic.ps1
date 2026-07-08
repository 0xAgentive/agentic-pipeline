$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwsh) { $pwsh = Get-Command powershell -ErrorAction Stop }
$RepoRoot = (Resolve-Path (Join-Path $ScriptRoot "..\..")).Path
$Fastpatch = Join-Path $RepoRoot "scripts/Test-FastPatchAllowed.ps1"
if (!(Test-Path $Fastpatch)) { throw "Missing fastpatch script: $Fastpatch" }

$Temp = Join-Path ([System.IO.Path]::GetTempPath()) ("fastpatch-synth-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $Temp | Out-Null
Push-Location $Temp
try {
  git init | Out-Null
  New-Item -ItemType Directory -Force "scripts" | Out-Null
  Copy-Item $Fastpatch "scripts/Test-FastPatchAllowed.ps1" -Force
  New-Item -ItemType Directory -Force "src/frontend/components" | Out-Null
  New-Item -ItemType Directory -Force "src/backend" | Out-Null
  Set-Content "src/frontend/components/AppSelect.tsx" "export const AppSelect = () => null" -Encoding UTF8
  git add . | Out-Null
  git commit -m init | Out-Null

  Set-Content "src/backend/new.ts" "export const x = 1" -Encoding UTF8
  & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File "scripts/Test-FastPatchAllowed.ps1" -RequireChanges | Out-Null
  if ($LASTEXITCODE -eq 0) { throw "Fastpatch failed to block untracked backend file" }
  Remove-Item "src/backend/new.ts" -Force

  Add-Content "src/frontend/components/AppSelect.tsx" "`nfetch('/api/x')"
  & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File "scripts/Test-FastPatchAllowed.ps1" -RequireChanges | Out-Null
  if ($LASTEXITCODE -eq 0) { throw "Fastpatch failed to block fetch" }
  git checkout -- "src/frontend/components/AppSelect.tsx"

  Add-Content "src/frontend/components/AppSelect.tsx" "`nimport { x } from '../../backend/new'"
  & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File "scripts/Test-FastPatchAllowed.ps1" -RequireChanges | Out-Null
  if ($LASTEXITCODE -eq 0) { throw "Fastpatch failed to block backend import" }

  Write-Host "Fastpatch synthetic tests passed."
} finally {
  Pop-Location
  Remove-Item $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
