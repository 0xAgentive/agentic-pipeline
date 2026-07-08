$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

$RequiredIgnore = @(
  "node_modules/",
  "dist/",
  "build/",
  ".git/",
  ".agy/checkpoints/",
  ".pipeline_patch_backup/",
  ".codebase-memory/",
  "coverage/",
  "*.log"
)

$Problems = @()

if (!(Test-Path ".cbmignore")) {
  $Problems += ".cbmignore missing"
} else {
  $Text = Get-Content ".cbmignore" -Raw
  foreach ($Entry in $RequiredIgnore) {
    if ($Text -notmatch [regex]::Escape($Entry)) {
      $Problems += ".cbmignore missing $Entry"
    }
  }
}

if (Test-Path ".gitignore") {
  $GitIgnore = Get-Content ".gitignore" -Raw
  foreach ($Entry in @(".pipeline_patch_backup/","*.bak-*")) {
    if ($GitIgnore -notmatch [regex]::Escape($Entry)) {
      $Problems += ".gitignore missing $Entry"
    }
  }
}

$HotFiles = @(
  ".agents\AGENTS.md",
  ".agents\rules\05-runtime-contract.md"
)

foreach ($Path in $HotFiles) {
  if (Test-Path $Path) {
    $Lines = (Get-Content $Path | Measure-Object -Line).Lines
    if ($Lines -gt 220) {
      $Problems += "$Path exceeds 220 lines"
    }
  }
}

if ($Problems.Count -gt 0) {
  Write-Error ("Context budget guard failed: " + ($Problems -join "; "))
  exit 1
}

Write-Host "Context budget guard OK."
exit 0