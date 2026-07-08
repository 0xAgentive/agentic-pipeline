$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

$requiredIgnores = @(
  "node_modules/",
  "dist/",
  "build/",
  ".git/",
  ".agy/checkpoints/",
  ".codebase-memory/",
  "coverage/",
  "*.log",
  "*.zip"
)

$files = @(".cbmignore", ".gitignore")
$missing = @()

foreach ($file in $files) {
  if (!(Test-Path $file)) {
    $missing += "$file missing"
    continue
  }

  $text = Get-Content $file -Raw
  foreach ($entry in $requiredIgnores) {
    if ($text -notmatch [regex]::Escape($entry)) {
      $missing += "$file missing $entry"
    }
  }
}

if ($missing.Count -gt 0) {
  Write-Host "Context budget guard failed:"
  $missing | ForEach-Object { Write-Host "- $_" }
  exit 1
}

Write-Host "Context budget gitignore guard OK."
exit 0
